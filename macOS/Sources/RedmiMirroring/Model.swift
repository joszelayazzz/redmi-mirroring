import SwiftUI
import AppKit
import Network

struct DiscoveredPhone: Identifiable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

@MainActor final class MirrorModel: ObservableObject {
    @Published var devices: [PairedDevice] = []
    @Published var nearby: [DiscoveredPhone] = []
    @Published var selectedId: String?
    @Published var state = "Ready to pair"
    @Published var detail = "Install the companion on your Redmi to get started."
    @Published var connected = false
    @Published var projection = false
    @Published var control = false
    @Published var hasAudio = false
    @Published var showPairing = false
    @Published var invitationText = ""
    @Published var rtt: Double = 0
    @Published var megabits: Double = 0
    // Per-frame timing is diagnostic data; publishing it would invalidate SwiftUI at video rate.
    private(set) var estimatedPacketAgeMs: Double = 0
    private var phoneClockOffsetMs: Double?
    private var bestRtt = Double.infinity
    @Published var transferMessage = ""
    @Published var discoveryError = ""
    let media = MediaPipeline()
    private let store = PairingStore()
    private let transport = SecureTransport()
    private let remote = NativeRemoteTunnel()
    private var remoteDeviceId: String?
    private var revoking = false
    private var revokeTimer: Timer?
    private var browser: NWBrowser?
    private var retry: Timer?
    private var heartbeat: Timer?
    private var attempt = 0
    private var pendingDevice: PairedDevice?
    private var manualStopped = false
    private var bytes = 0
    private var sampleTime = ProcessInfo.processInfo.systemUptime
    private var lastPong = ProcessInfo.processInfo.systemUptime
    private var observers = [NSObjectProtocol]()
    private var slowSamples = 0
    private var activeBitrate = 8_000_000
    private var activeMaximumDimension = 1920
    private var fallback: Timer?
    private var diagnosticTimer: Timer?
    private var connectionDeadline: Timer?
    private var qaController: NativeQAController?
    private var mirroringActivity: NSObjectProtocol?
    var current: PairedDevice? { devices.first { $0.id == selectedId } ?? pendingDevice }
    var streaming: Bool { connected && projection && media.framesReceived > 0 }
    var videoDeliveryMilliseconds: Double { transport.videoDeliveryMilliseconds }
    var maximumVideoDeliveryMilliseconds: Double { transport.maximumVideoDeliveryMilliseconds }
    // Explicit app-local QA enables a short, bounded trace. Normal sessions send no trace fields.
    var diagnosticInputTraceId: String?
    private(set) var diagnosticInputTraceRecords: [[String: Any]] = []
    private(set) var diagnosticStreamStats: [[String: Any]] = []
    private(set) var diagnosticEncoderInfo: [String: Any] = [:]
    private(set) var diagnosticConnectionEvents: [[String: Any]] = []
    private func noteConnectionEvent(_ event: String, reason: String? = nil) {
        guard ProcessInfo.processInfo.environment["REDMI_DIAGNOSTICS"] != nil else { return }
        var record: [String: Any] = ["event":event, "uptimeMs":ProcessInfo.processInfo.systemUptime * 1000]
        if let reason { record["reason"] = String(reason.prefix(256)) }
        diagnosticConnectionEvents.append(record)
        if diagnosticConnectionEvents.count > 24 { diagnosticConnectionEvents.removeFirst() }
    }
    func beginInputTrace() {
        diagnosticInputTraceRecords.removeAll(keepingCapacity: true)
        diagnosticStreamStats.removeAll(keepingCapacity: true)
        diagnosticInputTraceId = UUID().uuidString
    }
    func endInputTrace() -> [[String: Any]] {
        diagnosticInputTraceId = nil
        return diagnosticInputTraceRecords
    }

    init() {
        do { devices = try store.load(); selectedId = devices.first?.id } catch { detail = error.localizedDescription }
        if !devices.isEmpty { state = "Looking for your Redmi"; detail = "Start screen sharing in the companion when you’re ready." }
        transport.onState = { [weak self] state in self?.state = state }
        transport.onFrame = { [weak self] frame in self?.receive(frame) }
        transport.onFailure = { [weak self] reason, fatal in self?.failed(reason, fatal: fatal) }
        media.onInput = { [weak self] input in
            guard let self, self.connected, self.control else { return }
            var message = input
            if let trace = self.diagnosticInputTraceId, input["kind"] as? String == "pointer" {
                message["traceId"] = trace
                let sent = ProcessInfo.processInfo.systemUptime * 1000
                message["sentMacMs"] = sent
                if self.diagnosticInputTraceRecords.count < 128 {
                    var record: [String: Any] = ["traceId": trace, "stage": "sent", "sentMacMs": sent]
                    for field in ["phase", "seq", "source"] { if let value = input[field] { record[field] = value } }
                    self.diagnosticInputTraceRecords.append(record)
                }
            }
            self.transport.send(message)
        }
        if let diagnosticPath = ProcessInfo.processInfo.environment["REDMI_DIAGNOSTICS"] {
            diagnosticTimer = Timer.mirrorTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in
                guard let self else { return }
                let data: [String: Any] = ["state":self.state,"detail":self.detail,"connected":self.connected,"projection":self.projection,"control":self.control,"audio":self.hasAudio,"width":self.media.width,"height":self.media.height,"fps":self.media.fps,"decodeMs":self.media.decodeMilliseconds,"rttMs":self.rtt,"estimatedCapturePacketAgeMs":self.estimatedPacketAgeMs,"mbps":self.megabits,"receivedFrames":self.media.framesReceived,"framesEnqueued":self.media.framesEnqueued,"displayFramesDropped":self.media.displayFramesDropped,"livePointer":self.media.supportsLivePointer,"latestPresentationTimeUs":self.media.latestPresentationTimeUs,"droppedFrames":self.media.framesDropped,"hardwareDecoder":self.media.usesHardwareDecoder,"mediaError":self.media.errorMessage ?? "","audioFramesPlayed":self.media.audioFramesPlayed,"audioFramesReceived":self.media.audioFramesReceived,"audioFramesScheduled":self.media.audioFramesScheduled,"audioQueueResets":self.media.audioQueueResets,"audioQueuedFrames":self.media.audioQueuedFrames,"audioStartupMs":self.media.audioStartupMilliseconds,"audioRms":self.media.audioRms,"transfer":self.transferMessage]
                var diagnostics = data
                diagnostics["videoDeliveryMs"] = self.videoDeliveryMilliseconds
                diagnostics["maximumVideoDeliveryMs"] = self.maximumVideoDeliveryMilliseconds
                diagnostics["decoderCallbackDeliveryMs"] = self.media.decoderCallbackDeliveryMilliseconds
                diagnostics["maximumDecoderCallbackDeliveryMs"] = self.media.maximumDecoderCallbackDeliveryMilliseconds
                diagnostics["encoderInfo"] = self.diagnosticEncoderInfo
                diagnostics["connectionEvents"] = self.diagnosticConnectionEvents
                diagnostics["decoderInFlight"] = self.media.inFlightDecodes
                diagnostics["decoderMaximumInFlight"] = self.media.maximumInFlightDecodes
                diagnostics["decoderDropsByCause"] = ["waitingForKeyframe":self.media.framesDroppedWaitingForKeyframe,
                    "overload":self.media.framesDroppedOverload, "codecError":self.media.framesDroppedDecodeError,
                    "outOfOrder":self.media.framesDroppedOutOfOrder, "missingConfiguration":self.media.framesDroppedMissingConfiguration]
                if let json = try? JSONSerialization.data(withJSONObject:diagnostics,options:[.prettyPrinted,.sortedKeys]) { try? json.write(to:URL(fileURLWithPath:diagnosticPath),options:.atomic) }
            } }
        }
        if let path = ProcessInfo.processInfo.environment["REDMI_INVITATION_FILE"], let handle = try? FileHandle(forReadingFrom:URL(fileURLWithPath:path)), let data = try? handle.readToEnd(), let text = String(data:data,encoding:.utf8) {
            try? handle.close()
            try? FileManager.default.removeItem(atPath:path)
            invitationText = text
            DispatchQueue.main.async { [weak self] in self?.showPairing = true; self?.pair() }
        }
        if let path = ProcessInfo.processInfo.environment["REDMI_QA_COMMAND"] { qaController = NativeQAController(model:self,commandPath:path) }
        media.onNeedsKeyframe = { [weak self] in self?.transport.send(["type":"keyframe"]) }
        browse()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, !self.manualStopped else { return }; self.connect() }
        })
        if UserDefaults.standard.object(forKey:"autoConnect") as? Bool ?? true, !devices.isEmpty {
            fallback = Timer.mirrorTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in Task { @MainActor in self?.connect() } }
        }
    }
    func browse() {
        browser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_redmimirror._tcp.", domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredPhone? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var id = name
                if case .bonjour(let record) = result.metadata, let value = record["id"] { id = String(value) }
                return DiscoveredPhone(id: id, name: name, endpoint: result.endpoint)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.nearby = found.sorted { $0.name < $1.name }
                if !self.connected, !self.manualStopped, self.retry == nil,
                   UserDefaults.standard.object(forKey:"autoConnect") as? Bool ?? true,
                   let id = self.selectedId, self.devices.first(where: { $0.id == id })?.relay == nil, self.nearby.contains(where: { $0.id == id }) {
                    self.fallback?.invalidate(); self.connect()
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { DispatchQueue.main.async { self?.discoveryError = "Local discovery: \(error.localizedDescription). A saved address can still connect." } }
        }
        browser.start(queue: DispatchQueue(label:"com.redmimirroring.discovery"))
    }
    func pair() {
        connectionDeadline?.invalidate(); connectionDeadline = nil
        do {
            let invitation = try PairingInvitation(link: invitationText)
            if let saved = devices.first(where: { $0.id == invitation.id }) { selectedId = saved.id }
            let device = PairedDevice(invitation: invitation, clientId: UUID().uuidString)
            remote.stop(); remoteDeviceId = nil; transport.disconnect()
            pendingDevice = device
            manualStopped = false; retry?.invalidate(); retry = nil; heartbeat?.invalidate()
            media.reset(); connected = false; projection = false
            state = "Connecting securely"; detail = "Approve this Mac on your Redmi."
            transport.connect(device: device, pairing: true)
        } catch { state = "Check your invitation"; detail = error.localizedDescription }
    }
    func connect() {
        noteConnectionEvent("connect")
        connectionDeadline?.invalidate(); connectionDeadline = nil
        fallback?.invalidate(); fallback = nil
        guard let device = devices.first(where: { $0.id == selectedId }) else { return }
        transport.disconnect(); remote.stop(); remoteDeviceId = nil
        pendingDevice = nil; manualStopped = false; revoking = false
        retry?.invalidate(); retry = nil; heartbeat?.invalidate()
        connected = false; projection = false; hasAudio = false; media.reset()
        state = "Connecting securely"; detail = "Reaching \(device.name)…"
        if let relay = device.relay {
            remoteDeviceId = device.id
            state = "Reaching remote Redmi"; detail = "Waiting for the phone at your private relay…"
            remote.start(host:relay.host,port:relay.port,fingerprint:relay.fingerprint,room:relay.room,onReady:{ [weak self] port in
                guard let self, !self.manualStopped, self.remoteDeviceId == device.id else { return }
                self.transport.connect(device:device,endpoint:.hostPort(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!),pairing:false)
                self.armConnectionDeadline()
            },onFailure:{ [weak self] message in
                guard let self, !self.manualStopped else { return }
                self.transport.disconnect()
                self.noteConnectionEvent("remoteFailure",reason:message)
                self.connected = false; self.projection = false; self.media.reset(); self.state = "Waiting for remote Redmi"; self.detail = message
            })
        } else {
            remote.stop(); remoteDeviceId = nil
            let endpoint = nearby.first(where: { $0.id == device.id })?.endpoint
            transport.connect(device: device, endpoint: endpoint, pairing: false)
            armConnectionDeadline()
        }
    }
    func disconnect() {
        noteConnectionEvent("disconnect")
        connectionDeadline?.invalidate(); connectionDeadline = nil
        manualStopped = true; remote.stop(); remoteDeviceId = nil; fallback?.invalidate(); retry?.invalidate(); retry = nil; heartbeat?.invalidate()
        if let activity = mirroringActivity { ProcessInfo.processInfo.endActivity(activity); mirroringActivity = nil }
        transport.disconnect(); connected = false; projection = false; media.reset()
        state = "Disconnected"; detail = "Your Redmi is paired. Connect whenever you’re ready."
    }
    func suspend() {
        noteConnectionEvent("sleep")
        connectionDeadline?.invalidate(); connectionDeadline = nil
        remote.stop(); remoteDeviceId = nil
        if let activity = mirroringActivity { ProcessInfo.processInfo.endActivity(activity); mirroringActivity = nil }
        retry?.invalidate(); retry = nil; heartbeat?.invalidate(); transport.disconnect(); connected = false; media.reset()
        state = "Mac asleep"; detail = "The connection will resume after wake."
    }
    private func armConnectionDeadline() {
        connectionDeadline?.invalidate()
        connectionDeadline = Timer.mirrorTimer(withTimeInterval:8,repeats:false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.connected, !self.manualStopped, self.pendingDevice == nil else { return }
                self.transport.disconnect()
                self.failed("Your Redmi is taking too long to respond. Retrying…",fatal:false)
            }
        }
    }
    func simulateUnresponsiveConnectionForQA(port: UInt16) {
        guard let device = current, device.relay == nil else { return }
        transport.disconnect(); retry?.invalidate(); retry = nil; heartbeat?.invalidate()
        connected = false; projection = false; media.reset(); manualStopped = false
        state = "Connecting securely"
        transport.connect(device:device,endpoint:.hostPort(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!),pairing:false)
        armConnectionDeadline()
    }
    func unpair() {
        guard selectedId != nil else { return }
        if connected {
            revoking = true; control = false; state = "Removing pairing"
            transport.send(["type":"unpair"])
            revokeTimer?.invalidate()
            revokeTimer = Timer.mirrorTimer(withTimeInterval:2,repeats:false) { [weak self] _ in Task { @MainActor in self?.finishUnpair(confirmed:false) } }
        } else { finishUnpair(confirmed:false) }
    }
    private func finishUnpair(confirmed:Bool) {
        guard let id = selectedId else { return }
        revokeTimer?.invalidate(); revokeTimer = nil; revoking = false
        disconnect(); devices.removeAll { $0.id == id }
        do { try store.save(devices) } catch { detail = error.localizedDescription; return }
        selectedId = devices.first?.id; state = "Pairing removed"
        detail = confirmed ? "This Mac was revoked on your Redmi." : "Saved pairing removed. Revoke this Mac in the phone companion too; phone revocation was not confirmed."
    }
    func configureRelay(host:String, port:String, fingerprint:String, room:String) {
        let host = host.trimmingCharacters(in:.whitespacesAndNewlines)
        let pin = fingerprint.lowercased().replacingOccurrences(of:":",with:"").trimmingCharacters(in:.whitespacesAndNewlines)
        let token = room.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253, !host.contains(where:{ $0.isWhitespace }), !host.contains("/"), let portNumber = UInt16(port), portNumber > 0, PairingInvitation.validHex(pin), PairingInvitation.validHex(token), let index = devices.firstIndex(where:{ $0.id == selectedId }) else { detail = "Enter a valid relay address, port, SHA-256 certificate identity, and 256-bit room token."; return }
        devices[index].relay = RelayConfiguration(host:host,port:portNumber,fingerprint:pin,room:token)
        do { try store.save(devices); remote.stop(); remoteDeviceId = nil; transport.disconnect(); connect() } catch { detail = error.localizedDescription }
    }
    func useLocalConnection() {
        guard let index = devices.firstIndex(where:{ $0.id == selectedId }) else { return }
        devices[index].relay = nil
        do { try store.save(devices); remote.stop(); remoteDeviceId = nil; connect() } catch { detail = error.localizedDescription }
    }
    func updateEndpoint(_ host: String) {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 253, !clean.contains(where: { $0.isWhitespace || $0.isNewline }), !clean.contains("/"), let index = devices.firstIndex(where: { $0.id == selectedId }) else { return }
        devices[index].host = clean
        do { try store.save(devices); connect() } catch { detail = error.localizedDescription }
    }
    func simulateTransportInterruption() { transport.disconnect(); failed("The connection was interrupted.",fatal:false) }
    func sendAction(_ action: String) { guard connected, control else { return }; transport.send(["type":"input", "kind":"action", "action":action]) }
    func sendClipboard() {
        guard connected, let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 1_048_576 else { return }
        transport.send(["type":"clipboard", "text":text]); transferMessage = "Clipboard sent to your Redmi."
    }
    func pasteText() {
        guard connected, control, let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= 1_048_576 else { return }
        transport.send(["type":"input", "kind":"text", "value":text])
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { sendFile(url) }
    }
    func sendFile(_ url: URL) {
        guard connected else { return }
        transferMessage = "Sending \(url.lastPathComponent)…"
        transport.sendFile(url) { [weak self] result in
            switch result { case .success(let message): self?.transferMessage = message; case .failure(let error): self?.transferMessage = error.localizedDescription }
        }
    }
    func saveScreenshot() {
        guard let image = media.screenshot(), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png, properties:[:]) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Redmi Screenshot.png"; panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url { do { try png.write(to:url); transferMessage = "Screenshot saved." } catch { transferMessage = error.localizedDescription } }
    }
    func setQuality(override: String? = nil) {
        let preference = override ?? UserDefaults.standard.string(forKey:"quality") ?? "balanced"
        activeBitrate = preference == "detail" ? 12_000_000 : (["efficient", "responsive"].contains(preference) ? 4_000_000 : 8_000_000)
        activeMaximumDimension = preference == "detail" ? 2400 : (preference == "responsive" ? 1280 : 1920)
        transport.send(["type":"quality", "bitrate":activeBitrate, "fps":preference == "efficient" ? 30 : 60,
                        "maxDimension":activeMaximumDimension])
    }
    private func receive(_ frame: WireFrame) {
        bytes += frame.payload.count + 5
        if frame.type != 1 {
            guard connected else { failed("Media arrived before authentication.", fatal: true); return }
            switch frame.type { case 2: media.configure(frame.payload); case 3:
                if let offset = phoneClockOffsetMs, frame.payload.count >= 8 {
                    let pts = frame.payload.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    estimatedPacketAgeMs = max(0, ProcessInfo.processInfo.systemUptime * 1000 - (Double(pts)/1000 - offset))
                }
                media.decode(frame.payload); case 4: if UserDefaults.standard.object(forKey:"playAudio") as? Bool ?? true { media.playAudio(frame.payload) }; default: break }
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any], let type = json["type"] as? String else { failed("Invalid device response.", fatal:true); return }
        switch type {
        case "unpaired": if revoking { finishUnpair(confirmed:true) }
        case "pending": state = "Approve on your Redmi"; detail = "The companion is waiting for your permission to pair this Mac."
        case "ready":
            diagnosticEncoderInfo = [:]
            for field in ["encoder", "requestedLatencyFrames", "latencyHintApplied", "actualLatencyFrames"] {
                if let value = json[field] { diagnosticEncoderInfo[field] = value }
            }
            if let pending = pendingDevice {
                guard json["deviceId"] as? String == pending.id else { failed("The device identity changed during pairing.", fatal:true); return }
                devices.removeAll { $0.id == pending.id }; devices.append(pending)
                do { try store.save(devices) } catch { failed(error.localizedDescription, fatal:true); return }
                selectedId = pending.id; pendingDevice = nil; invitationText = ""; showPairing = false
            } else if let device = current, json["deviceId"] as? String != device.id { failed("The device identity changed.", fatal:true); return }
            if let name = json["name"] as? String, !name.isEmpty,
               let index = devices.firstIndex(where:{ $0.id == selectedId }), devices[index].name != name {
                devices[index].name = String(name.prefix(128))
                do { try store.save(devices) } catch { transferMessage = error.localizedDescription }
            }
            let first = !connected
            if first { noteConnectionEvent("authenticated") }
            connectionDeadline?.invalidate(); connectionDeadline = nil
            connected = true; attempt = 0
            if mirroringActivity == nil { mirroringActivity = ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Mirroring your Redmi") }
            projection = json["projection"] as? Bool ?? false; control = json["control"] as? Bool ?? false; hasAudio = json["audio"] as? Bool ?? false
            media.supportsLivePointer = control && (json["livePointer"] as? Bool == true)
            state = projection ? "Connected" : "Ready to share"
            detail = projection ? (control ? "Encrypted connection" : "Enable control in the phone companion.") : "Tap Start sharing on your Redmi and approve the Android screen-sharing dialog."
            if first { startHeartbeat(); setQuality() }
        case "captureStopped": noteConnectionEvent("captureStopped"); projection = false; media.reset(); state = "Sharing stopped"; detail = json["message"] as? String ?? "Approve a new screen-sharing session on your Redmi."
        case "error": failed(json["message"] as? String ?? "The phone refused the connection.", fatal:true)
        case "pong":
            guard connected, let sent = json["sent"] as? Double else { return }
            let received = ProcessInfo.processInfo.systemUptime * 1000
            rtt = max(0, received - sent); lastPong = ProcessInfo.processInfo.systemUptime
            if let phoneTime = json["phoneTime"] as? Double, rtt < bestRtt { bestRtt = rtt; phoneClockOffsetMs = phoneTime - (sent + received)/2 }
        case "clipboard":
            guard connected, UserDefaults.standard.bool(forKey:"receiveClipboard"), let text = json["text"] as? String, text.utf8.count <= 1_048_576 else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType:.string); transferMessage = "Phone clipboard received."
        case "fileResult": guard connected else { return }; transferMessage = json["message"] as? String ?? "File transfer completed."
        case "inputResult": guard connected else { return }; if json["ok"] as? Bool == false { transferMessage = json["message"] as? String ?? "Android could not perform that action." }
        case "inputTrace":
            guard connected, let trace = diagnosticInputTraceId, json["traceId"] as? String == trace,
                  diagnosticInputTraceRecords.count < 128 else { return }
            var record = json
            record["receivedMacMs"] = ProcessInfo.processInfo.systemUptime * 1000
            if let offset = phoneClockOffsetMs { record["phoneClockOffsetMs"] = offset }
            diagnosticInputTraceRecords.append(record)
        case "streamStats":
            guard connected, diagnosticInputTraceId != nil, diagnosticStreamStats.count < 16 else { return }
            diagnosticStreamStats.append(json)
        default: break
        }
    }
    private func startHeartbeat() {
        heartbeat?.invalidate(); bestRtt = .infinity; phoneClockOffsetMs = nil; sampleTime = ProcessInfo.processInfo.systemUptime; lastPong = sampleTime; bytes = 0
        heartbeat = Timer.mirrorTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in
            guard let self, self.connected else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastPong > 12 { self.transport.disconnect(); self.failed("Connection interrupted. Reconnecting…", fatal:false); return }
            self.megabits = Double(self.bytes * 8) / max(0.1, now - self.sampleTime) / 1_000_000; self.bytes = 0; self.sampleTime = now
            self.transport.send(["type":"ping", "sent":now * 1000])
            if self.rtt > 120 || self.media.decodeMilliseconds > 25 { self.slowSamples += 1 } else { self.slowSamples = 0 }
            if self.slowSamples >= 3, self.activeBitrate > 2_000_000 {
                self.activeBitrate = max(2_000_000, self.activeBitrate * 3 / 4); self.slowSamples = 0
                // A slow connection must never increase the phone encoder's pixel workload.
                self.activeMaximumDimension = min(self.activeMaximumDimension,1920)
                self.transport.send(["type":"quality", "bitrate":self.activeBitrate, "fps":30, "maxDimension":self.activeMaximumDimension])
            }
        } }
    }
    private func failed(_ reason: String, fatal: Bool) {
        noteConnectionEvent(fatal ? "refused" : "interrupted",reason:reason)
        connectionDeadline?.invalidate(); connectionDeadline = nil
        if let activity = mirroringActivity { ProcessInfo.processInfo.endActivity(activity); mirroringActivity = nil }
        connected = false; projection = false; media.reset(); heartbeat?.invalidate()
        state = fatal ? "Connection refused" : (pendingDevice != nil ? "Pairing interrupted" : "Reconnecting"); detail = reason
        if revoking { return }
        if remoteDeviceId != nil { if fatal { remote.stop(); remoteDeviceId = nil }; return }
        guard !fatal, !manualStopped, pendingDevice == nil, !devices.isEmpty else { transport.disconnect(); return }
        retry?.invalidate(); attempt += 1
        let delay = min(15.0, pow(2.0, Double(min(attempt,4))))
        retry = Timer.mirrorTimer(withTimeInterval: delay, repeats:false) { [weak self] _ in Task { @MainActor in self?.retry = nil; self?.connect() } }
    }
}
