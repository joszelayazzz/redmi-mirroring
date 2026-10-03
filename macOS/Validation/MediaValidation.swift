// Standalone native codec validation. This synthetic source is test data, never a device mock.
// Compile with Media.swift using swiftc -parse-as-library, then run on a Mac.
import AppKit
import Combine
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

private enum ValidationError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): return message } }
}

private func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    guard condition() else { throw ValidationError.failed(reason) }
}

@MainActor
private func waitForHardwareCallback(_ pipeline: MediaPipeline) throws {
    let deadline = CACurrentMediaTime() + 0.5
    while pipeline.inFlightDecodes > 0 && CACurrentMediaTime() < deadline {
        // This synchronous fixture deliberately keeps main delivery blocked.
        Thread.sleep(forTimeInterval: 0.0005)
    }
    try require(pipeline.inFlightDecodes == 0,
                "Completed decode kept a hardware slot while main delivery was waiting")
}

private final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    var config = Data()
    var packets: [Data] = []
    var failure: String?

    func append(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { failure = "Encoder omitted sample data"; return }
        if config.isEmpty {
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                guard result == noErr, let pointer else { failure = "Encoder omitted H264 parameters"; return }
                config.append(contentsOf: [0, 0, 0, 1])
                config.append(pointer, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        let result = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
        guard result == noErr else { failure = "Could not copy encoded data"; return }
        let stamp = CMSampleBufferGetPresentationTimeStamp(sample)
        var pts = UInt64(CMTimeConvertScale(stamp, timescale: 1_000_000, method: .default).value).bigEndian
        var packet = withUnsafeBytes(of: &pts) { Data($0) }
        var offset = 0
        while offset + 4 <= bytes.count {
            let count = bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard count > 0, count <= bytes.count - offset else { failure = "Invalid encoder AVCC data"; return }
            packet.append(contentsOf: [0, 0, 0, 1])
            packet.append(contentsOf: bytes[offset..<offset + count])
            offset += count
        }
        guard offset == bytes.count else { failure = "Encoder AVCC trailing bytes"; return }
        packets.append(packet)
    }
}

private func encode(width: Int32, height: Int32, count: Int) throws -> EncodedFrames {
    let frames = EncodedFrames()
    var session: VTCompressionSession?
    let result = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: width, height: height, codecType: kCMVideoCodecType_H264,
        encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: kCFAllocatorDefault,
        outputCallback: { reference, _, status, _, sample in
            guard let reference else { return }
            let frames = Unmanaged<EncodedFrames>.fromOpaque(reference).takeUnretainedValue()
            guard status == noErr, let sample else { frames.failure = "Encoder callback error \(status)"; return }
            frames.append(sample)
        }, refcon: Unmanaged.passUnretained(frames).toOpaque(), compressionSessionOut: &session)
    try require(result == noErr && session != nil, "Native H264 encoder unavailable: \(result)")
    guard let session else { throw ValidationError.failed("Native H264 session missing") }
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 8_000_000 as CFNumber)
    var buffer: CVPixelBuffer?
    let create = CVPixelBufferCreate(kCFAllocatorDefault, Int(width), Int(height), kCVPixelFormatType_32BGRA,
                                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    try require(create == kCVReturnSuccess && buffer != nil, "Could not allocate test pixel buffer")
    guard let buffer else { throw ValidationError.failed("Missing test pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let address = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<Int(height) {
            for x in 0..<Int(width) {
                let offset = y * stride + x * 4
                address[offset] = UInt8(x * 255 / Int(width))
                address[offset + 1] = UInt8(y * 255 / Int(height))
                address[offset + 2] = 180
                address[offset + 3] = 255
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    for index in 0..<count {
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(index), timescale: 60),
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: index == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            sourceFrameRefcon: nil, infoFlagsOut: nil)
        try require(status == noErr, "Native frame encode failed: \(status)")
    }
    let complete = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    try require(complete == noErr, "Native encoder completion failed")
    try require(frames.failure == nil, frames.failure ?? "Encoder callback failed")
    try require(frames.packets.count == count && !frames.config.isEmpty, "Encoder dropped test frames")
    return frames
}

@main
struct MediaValidation {
    @MainActor
    static func main() async {
        do {
            let invalid: [Data] = [Data(), Data([1, 2, 3]), Data([0, 0, 1]),
                                   Data([0, 0, 1, 0x80]), Data([0, 0, 1, 0x00]),
                                   Data([0, 0, 1, 0, 0, 1, 0x65, 0x88])]
            for data in invalid {
                do { _ = try H264AnnexB.units(data); throw ValidationError.failed("Accepted malformed Annex-B packet") }
                catch is MediaError { }
            }
            let mixed = try H264AnnexB.units(Data([0, 0, 0, 1, 0x67, 0x11, 0, 0, 1, 0x68, 0x22]))
            try require(mixed == [Data([0x67, 0x11]), Data([0x68, 0x22])], "Mixed start-code parsing failed")
            let avcc = try H264AnnexB.avcc(mixed)
            try require(avcc == Data([0, 0, 0, 2, 0x67, 0x11, 0, 0, 0, 2, 0x68, 0x22]), "AVCC conversion failed")
            print("PASS: malformed packets, mixed Annex-B start codes, AVCC conversion")

            let pipeline = MediaPipeline()
            pipeline.configure(Data([0, 0, 1, 0x67]))
            try require(pipeline.errorMessage != nil && pipeline.width == 0, "Invalid configuration was accepted")
            pipeline.reset()
            let source = try encode(width: 1080, height: 1920, count: 90)
            pipeline.configure(source.config)
            try require(pipeline.errorMessage == nil, pipeline.errorMessage ?? "Video configuration failed")
            try require(pipeline.width == 1080 && pipeline.height == 1920, "SPS screen dimensions incorrect")
            var interfaceNotifications = 0
            var firstFrameNotified = false
            let frameObserver = pipeline.objectWillChange.sink {
                interfaceNotifications += 1
                if pipeline.framesReceived == 0 { firstFrameNotified = true }
            }
            let frameStart = ProcessInfo.processInfo.systemUptime
            for (index, packet) in source.packets.enumerated() {
                pipeline.decode(packet)
                let target = frameStart + Double(index + 1) / 60
                let delay = max(0, target - ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(pipeline.errorMessage == nil, pipeline.errorMessage ?? "Video decode failed")
            try require(pipeline.framesReceived == 90 && pipeline.framesDropped == 0, "Codec loop lost frames")
            try require(pipeline.screenshot()?.size == NSSize(width: 1080, height: 1920), "Decoded screenshot missing or incorrectly sized")
            print(String(format: "PASS: native H264 1080×1920, %d frames, %.1f observed fps, %.3f ms mean-smoothed decode, hardware=%@, drops=%d",
                         pipeline.framesReceived, pipeline.fps, pipeline.decodeMilliseconds,
                         pipeline.usesHardwareDecoder ? "yes" : "no", pipeline.framesDropped))
            try require(firstFrameNotified && interfaceNotifications <= 4, "Video frames invalidated the interface repeatedly or omitted first-frame notification")
            try require(pipeline.decoderCallbackDeliveryMilliseconds.isFinite && pipeline.maximumDecoderCallbackDeliveryMilliseconds >= pipeline.decoderCallbackDeliveryMilliseconds, "Decoder callback queue diagnostics invalid")
            print("PASS: 90 frames generated \(interfaceNotifications) interface notifications including first frame; callback metrics valid")
            frameObserver.cancel()

            // Hardware finishes on its callback thread while the main actor deliberately
            // remains occupied. Finished work must not consume the eight codec slots.
            let burst = MediaPipeline()
            burst.configure(source.config)
            for packet in source.packets.prefix(24) {
                burst.decode(packet)
                try waitForHardwareCallback(burst)
            }
            try require(burst.framesReceived == 0, "Burst fixture unexpectedly serviced main delivery")
            try require(burst.framesDroppedOverload == 0 && burst.framesDroppedWaitingForKeyframe == 0,
                        "Completed decode work caused false overload/keyframe recovery")
            try await Task.sleep(nanoseconds: 150_000_000)
            try require(burst.framesReceived == 24 && burst.framesDropped == 0,
                        "Burst codec/main-delivery fixture lost frames")
            print("PASS: 24 genuine VT decodes release hardware slots before blocked main delivery; zero false-overload drops")
            burst.reset()

            let view = RemoteScreenView(pipeline: pipeline)
            view.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
            try require(view.normalized(CGPoint(x: 400, y: 400)) == CGPoint(x: 0.5, y: 0.5), "Display center mapping failed")
            try require(view.normalized(CGPoint(x: 10, y: 400)) == nil, "Letterbox input was accepted")
            try require(view.normalized(CGPoint(x: 0, y: 0), clamp: true) == .zero, "Drag clamping failed")
            var sent: [[String: Any]] = []
            pipeline.onInput = { sent.append($0) }
            view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            try require(view.hasMarkedText(), "IME marked text was lost")
            view.insertText("日本語 🐈 café", replacementRange: NSRange(location: NSNotFound, length: 0))
            try require(sent.last?["value"] as? String == "日本語 🐈 café" && !view.hasMarkedText(), "Unicode text commit was corrupted")
            view.doCommand(by: NSSelectorFromString("deleteBackward:"))
            try require(sent.last?["key"] as? String == "backspace", "Delete command was not forwarded")
            print("PASS: letterbox coordinates, clamp, Unicode IME commit, key forwarding")

            pipeline.supportsLivePointer = true
            func mouse(_ type:NSEvent.EventType,_ x:CGFloat,_ y:CGFloat,_ timestamp:Double) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:y),modifierFlags:[],timestamp:timestamp,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1) else { throw ValidationError.failed("Could not create native pointer fixture") }
                return event
            }
            sent.removeAll()
            view.mouseDown(with:try mouse(.leftMouseDown,400,400,1))
            try require(sent.last?["phase"] as? String == "down", "Pointer down waited for mouse up")
            view.mouseDragged(with:try mouse(.leftMouseDragged,410,380,1.03))
            try require(sent.last?["phase"] as? String == "move", "Drag was not forwarded before mouse up")
            view.mouseUp(with:try mouse(.leftMouseUp,420,360,1.06))
            try require(sent.compactMap{$0["phase"] as? String} == ["down","move","up"], "Live pointer phases changed order")
            try require(Set(sent.compactMap{$0["gestureId"] as? String}).count == 1 && sent.compactMap{$0["seq"] as? Int} == [1,2,3], "Pointer identity/sequence was invalid")
            view.mouseDown(with:try mouse(.leftMouseDown,400,400,2))
            view.flush()
            try require(sent.last?["phase"] as? String == "cancel", "Decoder reset left a held pointer")
            print("PASS: live pointer down/move before mouse up, identity, sequence, and cancellation")

            // Native wheel fixtures are delivered directly to this view, never posted globally.
            func wheel(_ dy: Int32, phase: Int64 = 0, momentum: Int64 = 0, y: CGFloat = 400) throws -> NSEvent {
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: dy, wheel2: 0, wheel3: 0) else {
                    throw ValidationError.failed("Could not create native scroll fixture")
                }
                event.location = CGPoint(x: 400, y: (NSScreen.screens.first?.frame.height ?? 0) - y)
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                guard let native = NSEvent(cgEvent: event), hypot(native.locationInWindow.x - 400, native.locationInWindow.y - y) < 1 else {
                    throw ValidationError.failed("Scroll fixture has no window-local position")
                }
                return native
            }
            sent.removeAll()
            view.scrollWheel(with: try wheel(24, phase: 1))
            try require(sent.compactMap { $0["phase"] as? String } == ["down", "move"], "Meaningful scroll did not send down and movement immediately")
            try require(sent.allSatisfy { $0["source"] as? String == "scroll" }, "Scroll lost pointer source metadata")
            let firstScrollId = sent.first?["gestureId"] as? String
            view.scrollWheel(with: try wheel(18, phase: 2))
            try await Task.sleep(nanoseconds: 50_000_000)
            try require(sent.filter { $0["phase"] as? String == "move" }.count >= 2, "Scroll movement waited for touch-up")
            try require(!sent.contains { $0["phase"] as? String == "up" }, "Scroll released before idle or end")
            try require(sent.allSatisfy { $0["gestureId"] as? String == firstScrollId }, "Continuous wheel events created separate swipes")
            let endedWheel = try wheel(0, phase: 4)
            try require(endedWheel.phase.contains(.ended), "Native phase fixture did not decode as ended")
            view.scrollWheel(with: endedWheel)
            // Momentum begins before the short end grace: preserve the same finger identity.
            view.scrollWheel(with: try wheel(15, momentum: 1))
            try await Task.sleep(nanoseconds: 35_000_000)
            try require(sent.allSatisfy { $0["gestureId"] as? String == firstScrollId } && !sent.contains { $0["phase"] as? String == "up" }, "Momentum interrupted the held scroll touch")
            view.scrollWheel(with: try wheel(0, momentum: 3))
            try await Task.sleep(nanoseconds: 90_000_000)
            try require(sent.last?["phase"] as? String == "up", "Momentum end left a held scroll touch")
            try require(sent.compactMap { $0["seq"] as? Int } == Array(1...sent.count), "Scroll sequence did not remain ordered")
            print("PASS: immediate scroll down/move, continued movement before up, joined momentum, ordered sequence and end release")

            sent.removeAll()
            view.scrollWheel(with: try wheel(1))
            try await Task.sleep(nanoseconds: 160_000_000)
            try require(sent.isEmpty, "Tiny trackpad noise created a phone touch")
            view.scrollWheel(with: try wheel(24))
            try await Task.sleep(nanoseconds: 160_000_000)
            try require(sent.last?["phase"] as? String == "up", "Phase-less wheel idle left a held touch")
            sent.removeAll()
            view.mouseDown(with: try mouse(.leftMouseDown, 400, 400, 3))
            view.scrollWheel(with: try wheel(24))
            try require(sent.count == 1 && sent.first?["source"] as? String == "mouse", "Scrolling replaced a direct mouse drag")
            view.mouseUp(with: try mouse(.leftMouseUp, 400, 400, 3.1))
            sent.removeAll()
            view.scrollWheel(with: try wheel(24))
            view.mouseDown(with: try mouse(.leftMouseDown, 400, 400, 4))
            try require(sent.compactMap { $0["phase"] as? String } == ["down", "move", "cancel", "down"], "Direct click failed to cancel scrolling before its own down")
            view.mouseUp(with: try mouse(.leftMouseUp, 400, 400, 4.1))
            sent.removeAll()
            view.scrollWheel(with: try wheel(24))
            view.flush()
            let countAfterFlush = sent.count
            try require(sent.last?["phase"] as? String == "cancel", "Stream flush did not cancel scrolling")
            try await Task.sleep(nanoseconds: 180_000_000)
            try require(sent.count == countAfterFlush, "Scroll timer sent input after stream flush")
            sent.removeAll()
            view.scrollWheel(with: try wheel(24))
            _ = view.resignFirstResponder()
            try require(sent.last?["phase"] as? String == "cancel", "Focus loss did not release scrolling")
            sent.removeAll()
            view.scrollWheel(with: try wheel(24))
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
            try require(sent.last?["phase"] as? String == "cancel", "App deactivation did not release scrolling")
            print("PASS: sub-slop noise, mouse/scroll exclusion, stream-reset cancellation without late events, focus cancellation")

            sent.removeAll()
            view.scrollWheel(with: try wheel(180, y: 80))
            try await Task.sleep(nanoseconds: 90_000_000)
            let scrollIds = Set(sent.compactMap { $0["gestureId"] as? String })
            try require(scrollIds.count >= 2, "Scroll did not recenter after exhausting a phone edge")
            for id in scrollIds {
                let gesture = sent.filter { $0["gestureId"] as? String == id }
                try require(gesture.first?["phase"] as? String == "down" && gesture.contains { $0["phase"] as? String == "move" }, "Edge restart created a stationary touch")
            }
            view.flush()
            pipeline.supportsLivePointer = false
            sent.removeAll()
            view.scrollWheel(with: try wheel(24))
            try require(sent.isEmpty, "Legacy wheel fallback changed its batching")
            try await Task.sleep(nanoseconds: 110_000_000)
            try require(sent.count == 1 && sent.first?["kind"] as? String == "scroll", "Older companion lost scroll fallback")
            view.flush()
            pipeline.supportsLivePointer = true
            print("PASS: edge release/recenter uses moving gestures; legacy companion scroll fallback preserved")

            let rotated = try encode(width: 1920, height: 1080, count: 5)
            pipeline.configure(rotated.config)
            for packet in rotated.packets { pipeline.decode(packet); try await Task.sleep(nanoseconds: 20_000_000) }
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(pipeline.screenshot()?.size == NSSize(width: 1920, height: 1080), "Orientation reconfiguration failed")
            try require(pipeline.errorMessage == nil && pipeline.framesDropped == 0, "Orientation reconfiguration lost frames")
            print("PASS: portrait-to-landscape codec reconfiguration")
            pipeline.reset()
            try require(pipeline.screenshot() == nil && pipeline.framesReceived == 0 && pipeline.width == 0, "Reset retained stale frame")
            print("PASS: reset clears decoder, metrics, and screenshot")
            // Silence exercises the real output engine and completion callback without making noise.
            pipeline.playAudio(Data(repeating: 0, count: 8 + 960 * 2))
            try await Task.sleep(nanoseconds: 500_000_000)
            try require(pipeline.errorMessage == nil, pipeline.errorMessage ?? "PCM audio failed")
            try require(pipeline.audioFramesPlayed == 960, "PCM output never completed")
            print("PASS: real audio output completed 960 PCM16 mono 48 kHz frames")
            pipeline.playAudio(Data(repeating: 0, count: 9))
            try require(pipeline.errorMessage != nil, "Malformed PCM audio was accepted")
            pipeline.reset()
            print("MEDIA VALIDATION PASSED. These are Mac component tests; no Android or network performance is implied.")
        } catch {
            fputs("MEDIA VALIDATION FAILED: \(error)\n", stderr)
            exit(1)
        }
    }
}
