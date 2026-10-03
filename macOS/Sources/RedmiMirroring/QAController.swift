import AppKit
import CoreGraphics
import Foundation

/// Explicitly enabled local QA only. Events are sent to this app's view, never posted globally.
/// The release app does not enable this unless REDMI_QA_COMMAND is supplied at launch.
@MainActor
final class NativeQAController {
    private weak var model: MirrorModel?
    private let commandURL: URL
    private let resultURL: URL
    private let workspaceRoot: URL
    private var timer: Timer?
    private var busy = false
    private var observations: [String:Any] = [:]

    init(model: MirrorModel, commandPath: String) {
        self.model = model
        commandURL = URL(fileURLWithPath: commandPath).standardizedFileURL.resolvingSymlinksInPath()
        resultURL = URL(fileURLWithPath: commandPath + ".result").standardizedFileURL.resolvingSymlinksInPath()
        var directory = commandURL.deletingLastPathComponent()
        var root = directory
        while directory.path != "/" {
            if directory.lastPathComponent == "work" || directory.lastPathComponent == "outputs" {
                root = directory.deletingLastPathComponent(); break
            }
            directory.deleteLastPathComponent()
        }
        workspaceRoot = root.resolvingSymlinksInPath()
        timer = Timer.mirrorTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    deinit { timer?.invalidate() }

    private enum QAError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): return message } }
    }

    private func poll() {
        guard !busy, FileManager.default.fileExists(atPath: commandURL.path), let model else { return }
        busy = true
        observations = [:]
        var action = "invalid"
        var identifier: String?
        let before = metrics(model)
        do {
            let values = try commandURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_048_576 else {
                throw QAError.invalid("Invalid QA command file.")
            }
            let data = try Data(contentsOf: commandURL)
            try FileManager.default.removeItem(at: commandURL)
            guard let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let requested = command["action"] as? String else { throw QAError.invalid("QA command needs an action.") }
            action = requested
            if let id = command["id"] as? String, id.count <= 128 { identifier = id }
            let delay = try perform(action, command: command, model: model)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak model] in
                guard let self else { return }
                if ["measureTouchLatency", "scrollSequence"].contains(action), let model {
                    self.observations["inputTrace"] = model.endInputTrace()
                    self.observations["phoneStreamStats"] = model.diagnosticStreamStats
                    self.observations["encoderInfo"] = model.diagnosticEncoderInfo
                }
                self.complete(action: action, id: identifier, before: before,
                              after: (model.map { self.metrics($0) } ?? [:]).merging(self.observations){_,new in new}, error: nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: commandURL)
            complete(action: action, id: identifier, before: before, after: metrics(model), error: error.localizedDescription)
        }
    }

    private func complete(action: String, id: String?, before: [String: Any], after: [String: Any], error: String?) {
        var result: [String: Any] = ["ok": error == nil, "action": action, "before": before, "after": after]
        if let id { result["id"] = id }
        if let error { result["message"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: resultURL, options: .atomic)
        }
        busy = false
    }

    private func metrics(_ model: MirrorModel) -> [String: Any] {
        ["connected": model.connected, "projection": model.projection, "control": model.control,
         "width": model.media.width, "height": model.media.height, "frames": model.media.framesReceived,
         "framesDropped": model.media.framesDropped, "fps": model.media.fps,
         "decodeMs": model.media.decodeMilliseconds, "rttMs": model.rtt,
         "estimatedCapturePacketAgeMs": model.estimatedPacketAgeMs,
         "framesEnqueued": model.media.framesEnqueued, "displayFramesDropped": model.media.displayFramesDropped,
         "videoDeliveryMs": model.videoDeliveryMilliseconds,
         "decoderCallbackDeliveryMs": model.media.decoderCallbackDeliveryMilliseconds,
         "hardwareDecoder": model.media.usesHardwareDecoder, "audioFramesPlayed": model.media.audioFramesPlayed,
         "state": model.state]
    }

    private func number(_ command: [String: Any], _ key: String, fallback: Double? = nil) throws -> Double {
        let result = (command[key] as? NSNumber)?.doubleValue ?? fallback
        guard let result, result.isFinite else { throw QAError.invalid("QA command has an invalid numeric argument.") }
        return result
    }

    private func normalized(_ command: [String: Any]) throws -> CGPoint {
        let x = try number(command, "x", fallback: 0.5), y = try number(command, "y", fallback: 0.5)
        guard (0...1).contains(x), (0...1).contains(y) else { throw QAError.invalid("QA coordinates must be normalized.") }
        return CGPoint(x: x, y: y)
    }

    private func window() throws -> NSWindow {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            throw QAError.invalid("The app has no visible window.")
        }
        return window
    }

    private func display(in view: NSView) -> RemoteScreenView? {
        if let screen = view as? RemoteScreenView { return screen }
        for child in view.subviews { if let screen = display(in: child) { return screen } }
        return nil
    }

    private func screen(_ model: MirrorModel) throws -> RemoteScreenView {
        guard model.connected, model.projection, model.control else { throw QAError.invalid("A shared, controllable phone is required.") }
        let window = try window()
        guard let content = window.contentView, let screen = display(in: content),
              screen.contentRect.width > 1, screen.contentRect.height > 1 else {
            throw QAError.invalid("The native mirrored display is not ready.")
        }
        return screen
    }

    private func localPoint(_ normalized: CGPoint, screen: RemoteScreenView) -> CGPoint {
        let rect = screen.contentRect
        // Stay inside CGRect's exclusive upper boundary, including coordinates exactly equal to one.
        let local = CGPoint(x: rect.minX + normalized.x * (rect.width - 0.001),
                            y: rect.minY + normalized.y * (rect.height - 0.001))
        return screen.convert(local, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, normalized: CGPoint, screen: RemoteScreenView,
                       timestamp: Double) throws -> NSEvent {
        guard let window = screen.window,
              let event = NSEvent.mouseEvent(with: type, location: localPoint(normalized, screen: screen),
                modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
            throw QAError.invalid("Could not create an app-local mouse event.")
        }
        return event
    }

    private func localURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw QAError.invalid("QA paths must be absolute workspace paths.") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(workspaceRoot.path + "/") else { throw QAError.invalid("QA file access is restricted to this workspace.") }
        return url
    }

    private func scrollEvent(dx: Double, dy: Double, at point: CGPoint, screen: RemoteScreenView,
                             ended: Bool = false) throws -> NSEvent {
        guard abs(dx) <= 2000, abs(dy) <= 2000,
              let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            throw QAError.invalid("Invalid QA scroll event.")
        }
        let local = localPoint(point, screen: screen)
        wheel.location = CGPoint(x: local.x, y: (NSScreen.screens.first?.frame.height ?? 0) - local.y)
        wheel.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if ended { wheel.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4) } // CG phase Ended, mapped to AppKit .ended.
        guard let event = NSEvent(cgEvent: wheel),
              hypot(event.locationInWindow.x - local.x, event.locationInWindow.y - local.y) < 1 else {
            throw QAError.invalid("Could not construct a window-local scroll event.")
        }
        return event
    }

    private func save(_ image: NSImage, path: String) throws {
        let url = try localURL(path)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw QAError.invalid("Could not encode the real image.") }
        try png.write(to: url, options: .atomic)
    }

    private func perform(_ action: String, command: [String: Any], model: MirrorModel) throws -> Double {
        switch action {
        case "stats": return 0
        case "quality":
            guard let profile = command["profile"] as? String,
                  ["efficient", "responsive", "balanced", "detail"].contains(profile) else {
                throw QAError.invalid("Unknown quality profile.")
            }
            if command["persist"] as? Bool == true { UserDefaults.standard.set(profile,forKey:"quality") }
            model.setQuality(override: profile); return 0.6
        case "foreground": NSApp.activate(ignoringOtherApps: true)
        case "connect": model.connect(); return 0.5
        case "disconnect": model.disconnect(); return 0.3
        case "interrupt": model.simulateTransportInterruption(); return 0.3
        case "unresponsiveConnection": model.simulateUnresponsiveConnectionForQA(port:39819); return 0.3
        case "navigate":
            guard let name = command["name"] as? String,
                  ["home", "back", "recents", "volumeUp", "volumeDown", "lock"].contains(name) else {
                throw QAError.invalid("Unsupported QA navigation action.")
            }
            model.sendAction(name)
        case "clipboard": model.sendClipboard()
        case "paste": model.pasteText()
        case "file":
            guard let path = (command["path"] ?? command["filePath"]) as? String else { throw QAError.invalid("QA file path is required.") }
            model.sendFile(try localURL(path)); return 0.3
        case "screenshot":
            guard let path = command["outputPath"] as? String, let image = model.media.screenshot() else {
                throw QAError.invalid("No real phone frame is available for the screenshot.")
            }
            try save(image, path: path)
        case "snapshotWindow":
            guard let path = command["outputPath"] as? String, let content = try window().contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw QAError.invalid("The app window cannot be captured.")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw QAError.invalid("Window PNG encoding failed.") }
            try png.write(to: localURL(path), options: .atomic)
        case "resize":
            let width = try number(command, "width"), height = try number(command, "height")
            guard (340...3000).contains(width), (540...3000).contains(height) else { throw QAError.invalid("Invalid QA window size.") }
            try window().setContentSize(NSSize(width: width, height: height)); return 0.3
        case "fullscreen": try window().toggleFullScreen(nil); return 0.8
        case "click":
            let screen = try screen(model), point = try normalized(command), start = ProcessInfo.processInfo.systemUptime
            screen.mouseDown(with: try mouse(.leftMouseDown, normalized: point, screen: screen, timestamp: start))
            screen.mouseUp(with: try mouse(.leftMouseUp, normalized: point, screen: screen, timestamp: start + 0.06))
        case "drag":
            let screen = try screen(model)
            guard let raw = command["points"] as? [[String: Any]], (2...128).contains(raw.count) else {
                throw QAError.invalid("QA drag requires two to 128 normalized points.")
            }
            let points = try raw.map { try normalized($0) }
            let duration = try number(command, "durationMs", fallback: 400)
            guard (60...5000).contains(duration) else { throw QAError.invalid("Invalid QA drag duration.") }
            let start = ProcessInfo.processInfo.systemUptime
            screen.mouseDown(with: try mouse(.leftMouseDown, normalized: points[0], screen: screen, timestamp: start))
            for index in 1..<points.count {
                let elapsed = duration / 1000 * Double(index) / Double(points.count - 1)
                let event = try mouse(.leftMouseDragged, normalized: points[index], screen: screen,timestamp:start+elapsed)
                DispatchQueue.main.asyncAfter(deadline:.now()+elapsed) { [weak screen] in screen?.mouseDragged(with:event) }
            }
            let end = try mouse(.leftMouseUp,normalized:points.last!,screen:screen,timestamp:start+duration/1000)
            DispatchQueue.main.asyncAfter(deadline:.now()+duration/1000) { [weak screen] in screen?.mouseUp(with:end) }
            return duration / 1000 + 0.4
        case "pointerDown", "pointerMove", "pointerUp":
            let screen = try screen(model), point = try normalized(command), now = ProcessInfo.processInfo.systemUptime
            let type:NSEvent.EventType = action == "pointerDown" ? .leftMouseDown : (action == "pointerMove" ? .leftMouseDragged : .leftMouseUp)
            let event = try mouse(type,normalized:point,screen:screen,timestamp:now)
            if action == "pointerDown" { screen.mouseDown(with:event) }
            else if action == "pointerMove" { screen.mouseDragged(with:event) }
            else { screen.mouseUp(with:event) }
        case "measureTouchLatency":
            let screen = try screen(model), point = try normalized(command)
            guard model.media.supportsLivePointer else { throw QAError.invalid("Live pointer input is required.") }
            let probe = CGPoint(x:try number(command,"probeX",fallback:0.9),y:try number(command,"probeY",fallback:0.328))
            guard (0...1).contains(probe.x), (0...1).contains(probe.y),
                  let baseline = model.media.decodedLuma(at:probe), (210...240).contains(baseline) else {
                throw QAError.invalid("The local QA canvas must be visible and released before measuring.")
            }
            let oldPTS = model.media.latestPresentationTimeUs, began = ProcessInfo.processInfo.systemUptime
            model.beginInputTrace()
            screen.mouseDown(with:try mouse(.leftMouseDown,normalized:point,screen:screen,timestamp:began))
            observations["nativeMouseDownCallMs"] = (ProcessInfo.processInfo.systemUptime-began)*1000
            Task { @MainActor [weak self,weak model,weak screen] in
                guard let self, let model, let screen else { return }
                var measured:Double?
                var responseLuma:Double?
                while ProcessInfo.processInfo.systemUptime-began < 2 {
                    guard model.connected, model.projection else { break }
                    if model.media.latestPresentationTimeUs > oldPTS,
                       let value = model.media.decodedLuma(at:probe), (180...215).contains(value), baseline-value > 14 {
                        measured = (ProcessInfo.processInfo.systemUptime-began)*1000
                        responseLuma = value
                        self.observations["responseCapturePacketAgeMs"] = model.estimatedPacketAgeMs
                        self.observations["responseRTTMs"] = model.rtt
                        self.observations["responseDecodeMs"] = model.media.decodeMilliseconds
                        self.observations["responseVideoDeliveryMs"] = model.videoDeliveryMilliseconds
                        self.observations["responseDecoderCallbackDeliveryMs"] = model.media.decoderCallbackDeliveryMilliseconds
                        break
                    }
                    try? await Task.sleep(nanoseconds:5_000_000)
                }
                let ended = ProcessInfo.processInfo.systemUptime
                if let event = try? self.mouse(.leftMouseUp,normalized:point,screen:screen,timestamp:ended) { screen.mouseUp(with:event) }
                self.observations["latencyConfirmed"] = measured != nil
                self.observations["inputToDecodedResponseMs"] = measured ?? -1
                self.observations["probeBaselineLuma"] = baseline
                self.observations["probeResponseLuma"] = responseLuma ?? -1
            }
            return 2.15
        case "type":
            guard let value = command["value"] as? String, value.utf8.count <= 8192 else { throw QAError.invalid("Invalid QA text argument.") }
            try screen(model).insertText(value, replacementRange: NSRange(location: NSNotFound, length: 0))
        case "key":
            guard let key = (command["key"] ?? command["value"]) as? String else { throw QAError.invalid("QA key is required.") }
            let selectors = ["backspace": "deleteBackward:", "enter": "insertNewline:", "tab": "insertTab:",
                "left": "moveLeft:", "right": "moveRight:", "up": "moveUp:", "down": "moveDown:", "escape": "cancelOperation:"]
            guard let selector = selectors[key] else { throw QAError.invalid("Unsupported QA key.") }
            try screen(model).doCommand(by: NSSelectorFromString(selector))
        case "scroll":
            let screen = try screen(model), point = try normalized(command)
            let dx = try number(command, "dx", fallback: 0), dy = try number(command, "dy", fallback: 0)
            screen.scrollWheel(with: try scrollEvent(dx: dx, dy: dy, at: point, screen: screen))
            return 0.25
        case "scrollSequence":
            let screen = try screen(model), point = try normalized(command)
            let dx = try number(command,"dx",fallback:0), dy = try number(command,"dy",fallback:8)
            let requestedCount = try number(command,"count",fallback:30)
            let duration = try number(command,"durationMs",fallback:500) / 1000
            guard (2...180).contains(requestedCount), requestedCount.rounded(.down) == requestedCount,
                  (0.1...5).contains(duration) else {
                throw QAError.invalid("Invalid QA scroll sequence.")
            }
            let count = Int(requestedCount)
            let event = try scrollEvent(dx:dx,dy:dy,at:point,screen:screen)
            let ending = try scrollEvent(dx:0,dy:0,at:point,screen:screen,ended:true)
            model.beginInputTrace()
            for index in 0..<count {
                DispatchQueue.main.asyncAfter(deadline:.now()+duration*Double(index)/Double(count-1)) { [weak screen] in
                    screen?.scrollWheel(with:event)
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+duration+0.001) { [weak screen] in
                screen?.scrollWheel(with:ending)
            }
            return duration+0.5
        default: throw QAError.invalid("Unsupported QA action.")
        }
        return 0.2
    }
}
