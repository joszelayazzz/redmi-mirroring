import AppKit
import AVFoundation
import AudioToolbox
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import SwiftUI
import VideoToolbox

enum MediaError: LocalizedError {
    case malformed(String)
    case codec(OSStatus)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): return reason
        case .codec(let status): return "The video decoder could not process this stream (\(status))."
        }
    }
}

/// Bounded Annex-B parser. Kept independent of VideoToolbox so malformed wire data can be tested.
enum H264AnnexB {
    static let maximumBytes = 16 * 1024 * 1024

    static func units(_ data: Data) throws -> [Data] {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw MediaError.malformed("The video packet has an invalid size.")
        }
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, 3)); index += 3; continue
                }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard let first = starts.first, bytes[..<first.offset].allSatisfy({ $0 == 0 }) else {
            throw MediaError.malformed("The video packet is missing an Annex-B start code.")
        }
        var result: [Data] = []
        for item in starts.indices {
            let start = starts[item].offset + starts[item].length
            var end = item + 1 < starts.count ? starts[item + 1].offset : bytes.count
            // Annex-B trailing_zero_8bits are outside the NAL unit's RBSP.
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            guard end > start, bytes[start] & 0x80 == 0, bytes[start] & 0x1f != 0 else {
                throw MediaError.malformed("The video packet contains an invalid NAL unit.")
            }
            guard result.count < 1024 else { throw MediaError.malformed("The video packet contains too many NAL units.") }
            result.append(Data(bytes[start..<end]))
        }
        return result
    }

    static func avcc(_ units: [Data]) throws -> Data {
        var result = Data()
        for unit in units {
            guard !unit.isEmpty, unit.count <= maximumBytes else {
                throw MediaError.malformed("The video packet contains an invalid NAL unit.")
            }
            var size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
            result.append(unit)
        }
        guard result.count <= maximumBytes else { throw MediaError.malformed("The video packet is too large.") }
        return result
    }

    static func timestamp(_ data: Data) throws -> UInt64 {
        guard data.count >= 8 else { throw MediaError.malformed("The media timestamp is incomplete.") }
        let value = data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard value <= UInt64(Int64.max) else { throw MediaError.malformed("The media timestamp is invalid.") }
        return value
    }
}

/// Each codec generation owns its budget. A callback can release a hardware slot on its
/// decoder thread even while display delivery is waiting on the main actor.
private final class DecodeSlotTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    private var peak = 0

    init(limit: Int) { self.limit = limit }

    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return count }
    var maximumInFlight: Int { lock.lock(); defer { lock.unlock() }; return peak }

    func acquire() -> DecodePermit? {
        lock.lock()
        guard count < limit else { lock.unlock(); return nil }
        count += 1; peak = max(peak, count)
        lock.unlock()
        return DecodePermit(tracker: self)
    }

    fileprivate func release() {
        lock.lock(); defer { lock.unlock() }
        count -= 1
        assert(count >= 0)
    }
}

extension Timer {
    /// Connection and media clocks must keep running while native menus or resizing track events.
    static func mirrorTimer(withTimeInterval interval: TimeInterval, repeats: Bool,
                            block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// Some codec failures can race their output callback with the submission result.
/// Exactly one completion owns the release and the frame's success/failure handling.
private final class DecodePermit: @unchecked Sendable {
    private let tracker: DecodeSlotTracker
    private let lock = NSLock()
    private var finished = false

    init(tracker: DecodeSlotTracker) { self.tracker = tracker }

    @discardableResult func complete() -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        finished = true
        lock.unlock()
        tracker.release()
        return true
    }

    deinit { complete() }
}

@MainActor
final class MediaPipeline: ObservableObject {
    @Published private(set) var width = 0
    @Published private(set) var height = 0
    @Published private(set) var fps = 0.0
    // The layer renders independently of SwiftUI. Per-frame diagnostics must not invalidate
    // the surrounding interface; the first frame and one-second FPS updates refresh its state.
    private(set) var decodeMilliseconds = 0.0
    private(set) var framesReceived = 0
    private(set) var framesDropped = 0
    private(set) var framesDroppedWaitingForKeyframe = 0
    private(set) var framesDroppedOverload = 0
    private(set) var framesDroppedDecodeError = 0
    private(set) var framesDroppedOutOfOrder = 0
    private(set) var framesDroppedMissingConfiguration = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var usesHardwareDecoder = false
    private(set) var latestPresentationTimeUs: UInt64 = 0
    private(set) var decoderCallbackDeliveryMilliseconds = 0.0
    private(set) var maximumDecoderCallbackDeliveryMilliseconds = 0.0
    private(set) var audioRms = 0.0
    private(set) var audioFramesPlayed = 0
    private(set) var audioFramesReceived = 0
    private(set) var audioFramesScheduled = 0
    private(set) var audioQueueResets = 0
    private(set) var framesEnqueued = 0
    private(set) var displayFramesDropped = 0
    var supportsLivePointer = false

    var onInput: (([String: Any]) -> Void)?
    var onNeedsKeyframe: (() -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var configuration: Data?
    private var generation: UInt64 = 0
    private var decodeSlots = DecodeSlotTracker(limit: 8)
    var inFlightDecodes: Int { decodeSlots.inFlight }
    var maximumInFlightDecodes: Int { decodeSlots.maximumInFlight }
    private var waitingForKeyframe = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrame: CMSampleBuffer?
    private var lastPTS: UInt64?
    private var fpsStart = 0.0
    private var fpsFrames = 0
    private var fpsTimer: Timer?
    fileprivate weak var display: RemoteScreenView?

    private lazy var audioEngine = AVAudioEngine()
    private lazy var audioPlayer = AVAudioPlayerNode()
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private var audioScheduledSinceStart: Int64 = 0
    private var audioStartupTargetFrames: Int64 = 3840
    private let audioMaximumQueuedFrames: Int64 = 11_520
    private var audioStartup: DispatchWorkItem?
    private var audioGeneration: UInt64 = 0
    private var audioObserver: NSObjectProtocol?
    private var audioInitialized = false
    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    init() { }

    private func configureAudio() throws {
        guard !audioInitialized else { return }
        // Some restricted sessions cannot access system Audio Units. Do not initialize a node
        // in that state: AVAudioPlayerNode can raise an Objective-C exception before Swift can catch it.
        var component = AudioComponentDescription(componentType: kAudioUnitType_Generator,
            componentSubType: kAudioUnitSubType_ScheduledSoundPlayer,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &component) != nil else {
            throw MediaError.malformed("System audio playback is unavailable in this session.")
        }
        audioEngine.attach(audioPlayer)
        audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: audioFormat)
        audioInitialized = true
        audioObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAudio() }
        }
    }

    deinit {
        fpsTimer?.invalidate()
        audioStartup?.cancel()
        if let session { VTDecompressionSessionInvalidate(session) }
        if let audioObserver { NotificationCenter.default.removeObserver(audioObserver) }
    }

    func configure(_ data: Data) {
        do {
            guard data.count <= 65_536 else { throw MediaError.malformed("The video configuration is too large.") }
            let units = try H264AnnexB.units(data)
            guard let sps = units.first(where: { $0.first! & 0x1f == 7 }), sps.count >= 4,
                  let pps = units.first(where: { $0.first! & 0x1f == 8 }), pps.count >= 2 else {
                throw MediaError.malformed("The phone did not send a valid H.264 screen configuration.")
            }
            var newFormat: CMFormatDescription?
            let status = sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    let pointers = [spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                    ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
                }
            }
            guard status == noErr, let newFormat else { throw MediaError.codec(status) }
            let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
            guard dimensions.width > 0, dimensions.height > 0,
                  dimensions.width <= 8192, dimensions.height <= 8192,
                  Int64(dimensions.width) * Int64(dimensions.height) <= 33_554_432 else {
                throw MediaError.malformed("The phone sent an unsupported screen size.")
            }
            // An unchanged config is common before every I-frame. Preserve decoder references.
            if configuration == data, session != nil { return }
            invalidateDecoder()
            format = newFormat
            configuration = data
            var newSession: VTDecompressionSession?
            let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ]
            let createStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: newFormat,
                decoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &newSession)
            guard createStatus == noErr, let newSession else { throw MediaError.codec(createStatus) }
            session = newSession
            VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            var hardware: Unmanaged<CFBoolean>?
            VTSessionCopyProperty(newSession, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  allocator: kCFAllocatorDefault, valueOut: &hardware)
            usesHardwareDecoder = hardware.map { CFBooleanGetValue($0.takeRetainedValue()) } ?? false
            if width != Int(dimensions.width) { width = Int(dimensions.width) }
            if height != Int(dimensions.height) { height = Int(dimensions.height) }
            display?.needsLayout = true
            display?.flush()
            if errorMessage != nil { errorMessage = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Wire payload: unsigned big-endian presentationTimeUs, followed by one Annex-B access unit.
    func decode(_ data: Data) {
        do {
            guard data.count > 8, data.count <= H264AnnexB.maximumBytes else {
                throw MediaError.malformed("The phone sent an incomplete video frame.")
            }
            let pts = try H264AnnexB.timestamp(data)
            let units = try H264AnnexB.units(Data(data.dropFirst(8)))
            guard units.contains(where: { let kind = $0.first! & 0x1f; return kind == 1 || kind == 5 }) else {
                throw MediaError.malformed("The video packet does not contain a picture.")
            }
            guard let session, let format else {
                framesDropped += 1; framesDroppedMissingConfiguration += 1
                return
            }
            let isKeyframe = units.contains(where: { $0.first! & 0x1f == 5 })
            if waitingForKeyframe && !isKeyframe {
                framesDropped += 1; framesDroppedWaitingForKeyframe += 1
                return
            }
            let avcc = try H264AnnexB.avcc(units.filter { let kind = $0.first! & 0x1f; return kind != 7 && kind != 8 && kind != 9 })
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
            guard status == noErr, let block else { throw MediaError.codec(status) }
            status = avcc.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: avcc.count)
            }
            guard status == noErr else { throw MediaError.codec(status) }
            var timing = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000),
                                            decodeTimeStamp: .invalid)
            var size = avcc.count
            var sample: CMSampleBuffer?
            status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                               formatDescription: format, sampleCount: 1,
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            guard status == noErr, let sample else { throw MediaError.codec(status) }
            // Bound actual codec work, rather than completed pictures waiting for main delivery.
            // Dropping a predicted picture still requires a fresh I-frame for safe recovery.
            guard let permit = decodeSlots.acquire() else {
                framesDropped += 1; framesDroppedOverload += 1
                if !waitingForKeyframe { waitingForKeyframe = true; onNeedsKeyframe?() }
                return
            }
            if isKeyframe { waitingForKeyframe = false }
            let submittedGeneration = generation
            let started = CACurrentMediaTime()
            status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
            ) { [weak self] result, flags, image, _, _ in
                guard permit.complete() else { return }
                let callbackTime = CACurrentMediaTime()
                let elapsed = (callbackTime - started) * 1000
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == submittedGeneration else { return }
                    let queueWait = max(0, (CACurrentMediaTime() - callbackTime) * 1000)
                    self.decoderCallbackDeliveryMilliseconds = queueWait
                    self.maximumDecoderCallbackDeliveryMilliseconds = max(self.maximumDecoderCallbackDeliveryMilliseconds, queueWait)
                    guard result == noErr, !flags.contains(.frameDropped), let image else {
                        self.framesDropped += 1; self.framesDroppedDecodeError += 1
                        if result != noErr { self.errorMessage = MediaError.codec(result).localizedDescription }
                        if !self.waitingForKeyframe { self.waitingForKeyframe = true; self.onNeedsKeyframe?() }
                        return
                    }
                    // Decoder callbacks can be out of order. Never render an older picture over a newer one.
                    if let last = self.lastPTS, pts < last {
                        self.framesDropped += 1; self.framesDroppedOutOfOrder += 1
                        return
                    }
                    self.lastPTS = pts
                    self.latestPresentationTimeUs = pts
                    self.decodeMilliseconds = self.decodeMilliseconds == 0 ? elapsed : self.decodeMilliseconds * 0.85 + elapsed * 0.15
                    self.present(image, pts: pts)
                }
            }
            if status != noErr, permit.complete() {
                waitingForKeyframe = true
                onNeedsKeyframe?()
                throw MediaError.codec(status)
            }
        } catch {
            framesDropped += 1; framesDroppedDecodeError += 1
            errorMessage = error.localizedDescription
        }
    }

    private func present(_ image: CVPixelBuffer, pts: UInt64) {
        var description: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                imageBuffer: image, formatDescriptionOut: &description)
        guard status == noErr, let description else { framesDropped += 1; framesDroppedDecodeError += 1; return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: Int64(pts), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                                                        formatDescription: description, sampleTiming: &timing,
                                                        sampleBufferOut: &sample)
        guard status == noErr, let sample else { framesDropped += 1; framesDroppedDecodeError += 1; return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if framesReceived == 0 { objectWillChange.send() }
        lastPixelBuffer = image
        lastFrame = sample
        framesReceived += 1
        let imageWidth = CVPixelBufferGetWidth(image), imageHeight = CVPixelBufferGetHeight(image)
        if width != imageWidth || height != imageHeight {
            if width != imageWidth { width = imageWidth }
            if height != imageHeight { height = imageHeight }
            display?.needsLayout = true
        }
        if let display {
            if display.enqueue(sample) { framesEnqueued += 1 }
            else { displayFramesDropped += 1 }
        }
        let now = CACurrentMediaTime()
        if fpsTimer == nil {
            fpsStart = now; fpsFrames = 0
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateFPS(now: CACurrentMediaTime())
                }
            }
            fpsTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            fpsFrames += 1
        }
        updateFPS(now: now)
        if errorMessage != nil { errorMessage = nil }
    }

    private func updateFPS(now: Double) {
        guard fpsStart > 0, now - fpsStart >= 0.99 else { return }
        fps = Double(fpsFrames) / (now - fpsStart)
        fpsStart = now; fpsFrames = 0
    }

    /// PCM16 little-endian, mono, 48 kHz. An 80 ms startup cushion absorbs LAN packet bursts.
    /// The render-clock queue has a 240 ms hard cap, excluding speaker/Bluetooth latency.
    func playAudio(_ data: Data) {
        do {
            _ = try H264AnnexB.timestamp(data)
            let payload = data.dropFirst(8)
            guard !payload.isEmpty, payload.count % 2 == 0, payload.count <= 96_000 else {
                throw MediaError.malformed("The phone sent an invalid audio packet.")
            }
            audioFramesReceived += payload.count / 2
            let energyBytes = [UInt8](payload)
            var squares = 0.0
            for i in stride(from:0,to:energyBytes.count,by:2) { let value = Double(Int16(bitPattern:UInt16(energyBytes[i]) | UInt16(energyBytes[i+1]) << 8))/32768; squares += value*value }
            audioRms = sqrt(squares / Double(energyBytes.count/2))
            try configureAudio()
            let count = AVAudioFrameCount(min(Int(audioMaximumQueuedFrames), payload.count / 2))
            if queuedAudioFrameCount + Int64(count) > audioMaximumQueuedFrames {
                audioQueueResets += 1
                // A genuine long stall needs more room on the next startup, up to 120 ms.
                // Ordinary delayed Wi-Fi batches remain queued and do not interrupt playback.
                audioStartupTargetFrames = min(5760, audioStartupTargetFrames + 960)
                stopAudio(resetEngine: false)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: count),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = count
            let bytes = [UInt8](payload.suffix(Int(count) * 2))
            for index in 0..<Int(count) {
                let bits = UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8
                channel[index] = Float(Int16(bitPattern: bits)) / 32768
            }
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }
            // If capture briefly starved, the player's clock continued through silence. Anchor
            // the new tail to that render clock instead of undercounting every later packet.
            audioScheduledSinceStart = max(audioScheduledSinceStart, renderedAudioFrameCount) + Int64(count)
            audioFramesScheduled += Int(count)
            let submittedGeneration = audioGeneration
            audioPlayer.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.audioGeneration == submittedGeneration else { return }
                    self.audioFramesPlayed += Int(count)
                }
            }
            if !audioPlayer.isPlaying {
                if audioScheduledSinceStart >= audioStartupTargetFrames { startAudioPlayer() }
                else if audioStartup == nil {
                    // A lone packet should still play; continuous capture normally supplies the
                    // next 20 ms packets before this bounded fallback fires.
                    let work = DispatchWorkItem { [weak self] in self?.startAudioPlayer() }
                    audioStartup = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(audioStartupTargetFrames) / 48_000 + 0.01, execute: work)
                }
            }
        } catch { errorMessage = "Audio: \(error.localizedDescription)" }
    }

    var audioQueuedFrames: Int { Int(queuedAudioFrameCount) }
    var audioStartupMilliseconds: Double { Double(audioStartupTargetFrames) / 48 }

    private var queuedAudioFrameCount: Int64 {
        guard audioInitialized, audioScheduledSinceStart > 0 else { return 0 }
        return max(0, audioScheduledSinceStart - renderedAudioFrameCount)
    }

    private var renderedAudioFrameCount: Int64 {
        guard audioInitialized else { return 0 }
        guard audioPlayer.isPlaying, let render = audioPlayer.lastRenderTime,
              let time = audioPlayer.playerTime(forNodeTime: render), time.sampleRate > 0 else {
            return 0
        }
        return Int64(max(0, Double(time.sampleTime) * 48_000 / time.sampleRate))
    }

    private func startAudioPlayer() {
        audioStartup?.cancel(); audioStartup = nil
        guard audioInitialized, audioEngine.isRunning, audioScheduledSinceStart > 0,
              !audioPlayer.isPlaying else { return }
        audioPlayer.play()
    }

    private func stopAudio(resetEngine: Bool = true) {
        guard audioInitialized else { return }
        audioStartup?.cancel(); audioStartup = nil
        audioGeneration &+= 1
        audioPlayer.stop()
        if resetEngine { audioEngine.stop(); audioEngine.reset() }
        audioScheduledSinceStart = 0
    }

    private func invalidateDecoder() {
        generation &+= 1
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        decodeSlots = DecodeSlotTracker(limit: 8)
        decoderCallbackDeliveryMilliseconds = 0
        maximumDecoderCallbackDeliveryMilliseconds = 0
        waitingForKeyframe = true
        lastPTS = nil
        lastPixelBuffer = nil
        lastFrame = nil
        usesHardwareDecoder = false
        fpsTimer?.invalidate(); fpsTimer = nil
        fps = 0; fpsStart = 0; fpsFrames = 0
    }

    func reset() {
        invalidateDecoder()
        format = nil; configuration = nil
        stopAudio()
        width = 0; height = 0; fps = 0; decodeMilliseconds = 0
        framesReceived = 0; framesDropped = 0; latestPresentationTimeUs = 0
        framesDroppedWaitingForKeyframe = 0; framesDroppedOverload = 0; framesDroppedDecodeError = 0
        framesDroppedOutOfOrder = 0; framesDroppedMissingConfiguration = 0
        framesEnqueued = 0; displayFramesDropped = 0
        audioFramesPlayed = 0; audioFramesReceived = 0; audioFramesScheduled = 0; audioQueueResets = 0; audioRms = 0
        audioStartupTargetFrames = 3840
        supportsLivePointer = false
        fpsStart = 0; fpsFrames = 0
        errorMessage = nil
        display?.flush()
    }

    func screenshot() -> NSImage? {
        guard let lastPixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: lastPixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Reads the actual decoded Y plane for the opt-in response-time QA fixture.
    func decodedLuma(at point:CGPoint) -> Double? {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              let image = lastPixelBuffer, CVPixelBufferGetPlaneCount(image) > 0 else { return nil }
        guard CVPixelBufferLockBaseAddress(image,.readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(image,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image,0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(image,0), height = CVPixelBufferGetHeightOfPlane(image,0)
        guard width >= 5, height >= 5 else { return nil }
        let x = min(width-3,max(2,Int(point.x*CGFloat(width)))), y = min(height-3,max(2,Int(point.y*CGFloat(height))))
        let row = CVPixelBufferGetBytesPerRowOfPlane(image,0), bytes = base.assumingMemoryBound(to:UInt8.self)
        var sum = 0.0
        for dy in -2...2 { for dx in -2...2 { sum += Double(bytes[(y+dy)*row+x+dx]) } }
        return sum/25
    }

    fileprivate func attach(_ view: RemoteScreenView) {
        display = view
        if let lastFrame { view.enqueue(lastFrame) }
    }
}

@MainActor
struct MirroredDisplay: NSViewRepresentable {
    @ObservedObject var pipeline: MediaPipeline

    func makeNSView(context: Context) -> RemoteScreenView {
        let view = RemoteScreenView(pipeline: pipeline)
        pipeline.attach(view)
        return view
    }

    func updateNSView(_ view: RemoteScreenView, context: Context) {
        if view.pipeline !== pipeline {
            view.pipeline = pipeline
            pipeline.attach(view)
            view.needsLayout = true
        }
    }
}

/// Native display and text input client. Coordinates use the same aspect-fit rectangle as the renderer.
@MainActor
final class RemoteScreenView: NSView, @preconcurrency NSTextInputClient {
    weak var pipeline: MediaPipeline?
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var dragPoints: [CGPoint] = []
    private var dragStart = 0.0
    private var lastDragSample = 0.0
    private enum PointerSource { case mouse, scroll }
    private var pointerId: String?
    private var pointerSource: PointerSource?
    private var pointerSequence = 0
    private var pointerPoint = CGPoint.zero
    private var pointerKeepalive: Timer?
    private var scrollDelta = CGPoint.zero
    private var scrollPoint = CGPoint(x: 0.5, y: 0.5)
    private var scrollWork: DispatchWorkItem?
    private var scrollFrameTimer: Timer?
    private var scrollIdleWork: DispatchWorkItem?
    private var focusObservers: [NSObjectProtocol] = []
    private var pinchScale = 1.0
    private var pinchPoint = CGPoint(x: 0.5, y: 0.5)
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private let compositionLabel = NSTextField(labelWithString: "")

    init(pipeline: MediaPipeline) {
        self.pipeline = pipeline
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        compositionLabel.isHidden = true
        compositionLabel.textColor = .white
        compositionLabel.backgroundColor = .black.withAlphaComponent(0.82)
        compositionLabel.drawsBackground = true
        compositionLabel.font = .systemFont(ofSize: 15)
        compositionLabel.wantsLayer = true
        compositionLabel.layer?.cornerRadius = 5
        addSubview(compositionLabel)
        setAccessibilityLabel("Mirrored Android display")
        setAccessibilityHelp("Click to touch the phone, drag to swipe, scroll with two fingers, and type to send text.")
        focusObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.cancelInteractions() } })
        focusObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? NSWindow, window === self.window else { return }
                self.cancelInteractions()
            }
        })
    }

    required init?(coder: NSCoder) { nil }
    deinit {
        pointerKeepalive?.invalidate()
        scrollFrameTimer?.invalidate()
        scrollIdleWork?.cancel()
        scrollWork?.cancel()
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
    }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelInteractions() }
        super.viewWillMove(toWindow:newWindow)
    }
    override func resignFirstResponder() -> Bool {
        cancelInteractions()
        return super.resignFirstResponder()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
        compositionLabel.frame = CGRect(x: max(8, (bounds.width - 240) / 2), y: max(8, bounds.height - 42),
                                         width: min(240, max(0, bounds.width - 16)), height: 28)
    }

    @discardableResult func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if #available(macOS 14.0, *) {
            let renderer = videoLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            guard renderer.isReadyForMoreMediaData else { return false }
            renderer.enqueue(sample)
            return true
        }
        if videoLayer.status == .failed { videoLayer.flush() }
        // Never let stale frames accumulate in the display layer.
        guard videoLayer.isReadyForMoreMediaData else { return false }
        videoLayer.enqueue(sample)
        return true
    }

    func flush() {
        cancelInteractions()
        if #available(macOS 14.0, *) {
            videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else { videoLayer.flushAndRemoveImage() }
    }

    var contentRect: CGRect {
        guard let pipeline, pipeline.width > 0, pipeline.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(pipeline.width), bounds.height / CGFloat(pipeline.height))
        let size = CGSize(width: CGFloat(pipeline.width) * scale, height: CGFloat(pipeline.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func normalized(_ point: CGPoint, clamp: Bool = false) -> CGPoint? {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (point.y - rect.minY) / rect.height)))
    }

    private func point(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        normalized(convert(event.locationInWindow, from: nil), clamp: clamp)
    }

    private func send(_ body: [String: Any]) {
        var message = body; message["type"] = "input"
        pipeline?.onInput?(message)
    }

    private func sendPointer(_ phase:String, at point:CGPoint) {
        guard let pointerId else { return }
        pointerSequence += 1
        send(["kind":"pointer", "phase":phase, "gestureId":pointerId, "seq":pointerSequence,
              "x":Double(point.x), "y":Double(point.y), "source":pointerSource == .scroll ? "scroll" : "mouse"])
    }

    private func beginPointer(at point: CGPoint, source: PointerSource) {
        pointerId = UUID().uuidString; pointerSequence = 0; pointerPoint = point; pointerSource = source
        sendPointer("down", at: point)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pointerId != nil else { return }
                self.sendPointer("move", at: self.pointerPoint)
            }
        }
        pointerKeepalive = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishPointer(_ phase:String, at point:CGPoint) {
        sendPointer(phase,at:point)
        pointerKeepalive?.invalidate(); pointerKeepalive = nil; pointerId = nil; pointerSource = nil
    }

    private func cancelPointer() {
        if pointerId != nil { finishPointer("cancel",at:pointerPoint) }
    }

    private func cancelInteractions() {
        endLiveScroll(cancel: true)
        cancelPointer()
        dragPoints.removeAll(keepingCapacity: true)
        scrollWork?.cancel(); scrollWork = nil; scrollDelta = .zero
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = point(event) else { return }
        cancelInteractions()
        window?.makeFirstResponder(self)
        dragPoints = [point]
        dragStart = event.timestamp
        lastDragSample = event.timestamp
        if pipeline?.supportsLivePointer == true {
            beginPointer(at: point, source: .mouse)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragPoints.isEmpty, let point = point(event, clamp: true) else { return }
        if pointerId != nil {
            pointerPoint = point
            if event.timestamp - lastDragSample >= 0.016 {
                sendPointer("move",at:point); lastDragSample = event.timestamp
            }
            return
        }
        if event.timestamp - lastDragSample >= 0.016, dragPoints.count < 128 {
            dragPoints.append(point); lastDragSample = event.timestamp
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragPoints.first, let end = point(event, clamp: true) else { return }
        if pointerId != nil {
            finishPointer("up",at:end); dragPoints.removeAll(keepingCapacity:true); return
        }
        let duration = min(10_000, max(50, Int((event.timestamp - dragStart) * 1000)))
        let rect = contentRect
        let distance = hypot((start.x - end.x) * rect.width, (start.y - end.y) * rect.height)
        let traveled = zip(dragPoints, dragPoints.dropFirst()).reduce(0.0) {
            $0 + hypot(Double(($1.1.x - $1.0.x) * rect.width), Double(($1.1.y - $1.0.y) * rect.height))
        }
        if distance < 4, traveled < 6, duration < 500 {
            send(["kind": "tap", "x": Double(end.x), "y": Double(end.y)])
        } else {
            dragPoints.append(end)
            send(["kind": "drag", "points": dragPoints.map { ["x": Double($0.x), "y": Double($0.y)] },
                  "durationMs": duration])
        }
        dragPoints.removeAll(keepingCapacity: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard point(event) != nil else { return }
        cancelInteractions()
        send(["kind": "action", "action": "back"])
    }

    override func scrollWheel(with event: NSEvent) {
        // A wheel event cannot replace a mouse-held touch or a legacy drag in progress.
        guard dragPoints.isEmpty, pointerSource != .mouse else { return }
        guard let point = point(event) else { return }
        guard event.scrollingDeltaX.isFinite, event.scrollingDeltaY.isFinite else { return }
        if pipeline?.supportsLivePointer == true {
            liveScroll(with: event, at: point)
            return
        }
        scrollPoint = point
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let rect = contentRect
        scrollDelta.x += event.scrollingDeltaX * multiplier / rect.width
        scrollDelta.y += event.scrollingDeltaY * multiplier / rect.height
        if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
            flushScroll()
        } else if scrollWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.flushScroll() }
            scrollWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    private func liveScroll(with event: NSEvent, at point: CGPoint) {
        if event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled) {
            endLiveScroll(cancel: true)
            return
        }
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return }
        if scrollFrameTimer == nil {
            scrollPoint = point
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushLiveScroll() }
            }
            scrollFrameTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        scrollDelta.x += event.scrollingDeltaX * multiplier / rect.width
        scrollDelta.y += event.scrollingDeltaY * multiplier / rect.height
        // Bound catch-up to five short segments. A delayed or extreme wheel event must not
        // keep moving the phone long after the user has stopped scrolling.
        let distance = hypot(scrollDelta.x * rect.width, scrollDelta.y * rect.height)
        let limit = min(rect.width, rect.height) * 0.5
        if distance > limit {
            scrollDelta.x *= limit / distance; scrollDelta.y *= limit / distance
        }
        // The first meaningful event sends DOWN and MOVE immediately; later events share
        // one held touch and the display-rate timer instead of creating independent swipes.
        if pointerId == nil { flushLiveScroll() }
        scrollIdleWork?.cancel()
        let ending = event.phase.contains(.ended) || event.momentumPhase.contains(.ended)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flushLiveScroll()
            self.endLiveScroll(cancel: false)
        }
        scrollIdleWork = work
        // A short end grace joins the finger's end to the following momentum-began event.
        DispatchQueue.main.asyncAfter(deadline: .now() + (ending ? 0.048 : 0.12), execute: work)
    }

    private func flushLiveScroll() {
        guard pipeline?.supportsLivePointer == true, dragPoints.isEmpty, pointerSource != .mouse else {
            endLiveScroll(cancel: true)
            return
        }
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { endLiveScroll(cancel: true); return }
        let distance = hypot(scrollDelta.x * rect.width, scrollDelta.y * rect.height)
        guard distance > 0.0001 else { return }
        if pointerId == nil {
            // Do not start a stationary touch for sub-slop trackpad noise: Android's
            // continued-stroke API ends as touch-up, which could otherwise click a control.
            guard distance >= max(3, min(rect.width, rect.height) * 0.025) else { return }
            let start = CGPoint(x: min(0.88, max(0.12, scrollPoint.x)),
                                y: min(0.88, max(0.12, scrollPoint.y)))
            beginPointer(at: start, source: .scroll)
        }
        guard pointerSource == .scroll else { return }
        let portion = min(1, min(rect.width, rect.height) * 0.1 / distance)
        let step = CGPoint(x: scrollDelta.x * portion, y: scrollDelta.y * portion)
        let target = CGPoint(x: min(0.94, max(0.06, pointerPoint.x + step.x)),
                             y: min(0.94, max(0.06, pointerPoint.y + step.y)))
        let consumed = CGPoint(x: target.x - pointerPoint.x, y: target.y - pointerPoint.y)
        scrollDelta.x -= consumed.x; scrollDelta.y -= consumed.y
        if abs(consumed.x) + abs(consumed.y) > 0.0001 {
            pointerPoint = target
            sendPointer("move", at: target)
        }
        if abs(consumed.x - step.x) + abs(consumed.y - step.y) > 0.0001 {
            // Lift at the edge and restart on the next timer tick only if enough residual
            // movement exists for another swipe. A zero-distance restart never becomes a tap.
            scrollPoint = target
            if abs(consumed.x - step.x) > 0.0001 { scrollPoint.x = 0.5 }
            if abs(consumed.y - step.y) > 0.0001 { scrollPoint.y = 0.5 }
            finishPointer("up", at: target)
        }
    }

    private func endLiveScroll(cancel: Bool) {
        scrollFrameTimer?.invalidate(); scrollFrameTimer = nil
        scrollIdleWork?.cancel(); scrollIdleWork = nil
        if pointerSource == .scroll { finishPointer(cancel ? "cancel" : "up", at: pointerPoint) }
        scrollDelta = .zero
    }

    private func flushScroll() {
        scrollWork?.cancel(); scrollWork = nil
        let dx = min(0.4, max(-0.4, scrollDelta.x)), dy = min(0.4, max(-0.4, scrollDelta.y))
        scrollDelta = .zero
        guard abs(dx) + abs(dy) > 0.0001 else { return }
        send(["kind": "scroll", "x": Double(scrollPoint.x), "y": Double(scrollPoint.y),
              "dx": Double(dx), "dy": Double(dy)])
    }

    override func magnify(with event: NSEvent) {
        guard let point = point(event) else { return }
        if event.phase.contains(.began) { cancelInteractions(); pinchScale = 1; pinchPoint = point }
        pinchScale *= max(0.05, 1 + Double(event.magnification))
        if event.phase.contains(.ended) {
            send(["kind": "pinch", "x": Double(pinchPoint.x), "y": Double(pinchPoint.y),
                  "scale": min(5, max(0.2, pinchScale))])
            pinchScale = 1
        } else if event.phase.contains(.cancelled) { pinchScale = 1 }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        interpretKeyEvents([event])
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        guard !text.isEmpty else { return }
        send(["kind": "text", "value": text])
    }

    override func doCommand(by selector: Selector) {
        let commands = ["deleteBackward:": "backspace", "deleteForward:": "backspace",
                        "insertNewline:": "enter", "insertLineBreak:": "enter", "insertTab:": "tab",
                        "moveLeft:": "left", "moveRight:": "right", "moveUp:": "up", "moveDown:": "down",
                        "cancelOperation:": "escape"]
        if let key = commands[NSStringFromSelector(selector)] { send(["kind": "key", "key": key]) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        markedSelection = selectedRange
        compositionLabel.stringValue = markedText.string
        compositionLabel.isHidden = markedText.length == 0
    }

    func unmarkText() {
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: 0, length: 0)
        compositionLabel.isHidden = true
    }

    func selectedRange() -> NSRange { markedSelection }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .foregroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= markedText.length else { return nil }
        let clipped = NSRange(location: range.location, length: min(range.length, markedText.length - range.location))
        actualRange?.pointee = clipped
        return markedText.attributedSubstring(from: clipped)
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange()
        let caret = NSRect(x: contentRect.midX, y: contentRect.maxY - 40, width: 1, height: 24)
        return window?.convertToScreen(convert(caret, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
