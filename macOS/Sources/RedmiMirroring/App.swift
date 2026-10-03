import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main struct RedmiMirroringApp: App {
    @StateObject private var model = MirrorModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Redmi Mirroring") {
            MirrorWindow(model:model)
                .frame(minWidth:340, minHeight:540)
                .onOpenURL { url in model.invitationText = url.absoluteString; model.showPairing = true }
        }
        .defaultSize(width:410, height:820)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Pair a Redmi…") { model.showPairing = true }.keyboardShortcut("n") }
            CommandMenu("Phone") {
                Button("Connect") { model.connect() }.keyboardShortcut("r").disabled(model.devices.isEmpty || model.connected)
                Button("Disconnect") { model.disconnect() }.disabled(!model.connected)
                Divider()
                Button("Back") { model.sendAction("back") }.keyboardShortcut("[",modifiers:.command).disabled(!model.control || !model.connected)
                Button("Home") { model.sendAction("home") }.keyboardShortcut("h",modifiers:[.command,.shift]).disabled(!model.control || !model.connected)
                Button("Recents") { model.sendAction("recents") }.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(!model.control || !model.connected)
                Button("Volume Up") { model.sendAction("volumeUp") }.keyboardShortcut("=",modifiers:.command).disabled(!model.connected)
                Button("Volume Down") { model.sendAction("volumeDown") }.keyboardShortcut("-",modifiers:.command).disabled(!model.connected)
                Button("Lock Redmi") { model.sendAction("lock") }.keyboardShortcut("l",modifiers:[.command,.shift]).disabled(!model.control || !model.connected)
                Divider()
                Button("Paste into Redmi") { model.pasteText() }.keyboardShortcut("v").disabled(!model.connected || !model.control)
                Button("Send Clipboard") { model.sendClipboard() }.keyboardShortcut("c",modifiers:[.command,.shift]).disabled(!model.connected)
                Button("Send File…") { model.chooseFile() }.keyboardShortcut("o").disabled(!model.connected)
                Button("Save Screenshot…") { model.saveScreenshot() }.keyboardShortcut("s",modifiers:[.command,.shift]).disabled(!model.streaming)
                Button("Enter Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f",modifiers:[.control,.command])
            }
        }
        Settings { MirrorSettings(model:model).frame(width:480,height:560) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        if let path = ProcessInfo.processInfo.environment["REDMI_WINDOW_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline:.now()+3) {
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
                view.cacheDisplay(in:view.bounds,to:bitmap)
                if let png = bitmap.representation(using:.png,properties:[:]) { try? png.write(to:URL(fileURLWithPath:path)) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { true }
}

struct MirrorWindow: View {
    @ObservedObject var model: MirrorModel
    @ObservedObject var media: MediaPipeline
    @StateObject private var ui = WindowUIState()
    init(model:MirrorModel) { self.model = model; media = model.media }
    var body: some View {
        VStack(spacing:0) {
            ZStack {
                if model.connected && model.projection {
                    MirroredDisplay(pipeline:media)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius:18,style:.continuous))
                        .padding(10)
                    if media.framesReceived == 0 {
                        VStack(spacing:12) { ProgressView(); Text("Waiting for the first frame").font(.callout).foregroundStyle(.secondary) }
                            .padding(20).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                    }
                    VStack { Spacer(); controls.opacity(ui.hovering ? 1 : 0) }.padding(.bottom,24)
                } else { welcome }
            }
            .frame(maxWidth:.infinity,maxHeight:.infinity)
            .onHover { ui.hovering = $0 }
            .animation(.easeOut(duration:0.15),value:ui.hovering)
            .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { providers in
                guard model.connected, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass:URL.self) { url, _ in guard let url else { return }; Task { @MainActor in model.sendFile(url) } }
                return true
            }
            Divider()
            if let message = media.errorMessage {
                Label(message, systemImage:"exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.horizontal,14).padding(.vertical,8)
                Divider()
            }
            if !model.transferMessage.isEmpty {
                HStack(spacing:8) {
                    Text(model.transferMessage).font(.caption).lineLimit(2)
                    Spacer(minLength:0)
                    Button { model.transferMessage = "" } label: { Image(systemName:"xmark") }
                        .buttonStyle(.plain).help("Dismiss")
                }.foregroundStyle(.secondary).padding(.horizontal,14).padding(.vertical,8)
                Divider()
            }
            HStack(spacing:7) {
                Circle().fill(model.connected ? Color.green : Color.secondary.opacity(0.45)).frame(width:6,height:6)
                Text(model.state).font(.system(size:11,weight:.medium)).lineLimit(1)
                Spacer()
                if model.streaming {
                    Text("\(Int(media.fps)) fps · \(Int(model.rtt)) ms RTT")
                        .font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                        .help("Measured frame rate and network round-trip time. RTT is not glass-to-glass video latency.")
                }
                if model.connected { Image(systemName:"lock.fill").font(.system(size:10)).foregroundStyle(.secondary).help("Certificate-pinned TLS encryption") }
            }.padding(.horizontal,14).padding(.vertical,10)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .tint(Color(red:0.89,green:0.22,blue:0.16))
        .toolbar {
            ToolbarItem(placement:.principal) {
                if model.devices.count > 1 {
                    Picker("Device",selection:$model.selectedId) { ForEach(model.devices) { device in Text(device.name).tag(Optional(device.id)) } }.labelsHidden().onChange(of:model.selectedId) { model.connect() }
                } else { Text(model.current?.name ?? "Redmi Mirroring").font(.headline) }
            }
            ToolbarItem(placement:.automatic) {
                Menu {
                    Button("Pair a Redmi…") { model.showPairing = true }
                    if !model.devices.isEmpty { Button(model.connected ? "Disconnect" : "Connect") { model.connected ? model.disconnect() : model.connect() } }
                    Divider()
                    Button("Send Clipboard") { model.sendClipboard() }.disabled(!model.connected)
                    Button("Send File…") { model.chooseFile() }.disabled(!model.connected)
                    Button("Save Screenshot…") { model.saveScreenshot() }.disabled(!model.streaming)
                    SettingsLink { Text("Settings…") }
                } label: { Image(systemName:"ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }
        }
        .sheet(isPresented:$model.showPairing) { pairing }
    }
    private var welcome: some View {
        VStack(spacing:20) {
            Spacer(minLength:20)
            Image(systemName:model.devices.isEmpty ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.system(size:62,weight:.ultraLight)).foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing:9) {
                Text(model.devices.isEmpty ? "Your Redmi. On your Mac." : model.state).font(.system(size:22,weight:.semibold))
                Text(model.detail).font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth:290)
            }
            if model.connected {
                ProgressView().controlSize(.small)
            } else if model.devices.isEmpty {
                Button("Pair your Redmi") { model.showPairing = true }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button("Connect") { model.connect() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            if model.devices.isEmpty {
                VStack(alignment:.leading,spacing:14) {
                    instruction("1", "Open Redmi Mirroring on your phone")
                    instruction("2", "Share its pairing invitation with this Mac")
                    instruction("3", "Approve pairing and screen sharing")
                }.padding(.top,12)
            }
            if !model.nearby.isEmpty {
                Text("\(model.nearby.count) companion\(model.nearby.count == 1 ? "" : "s") nearby").font(.caption).foregroundStyle(.secondary)
            }
            if !model.discoveryError.isEmpty { Text(model.discoveryError).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal,22) }
            Spacer(minLength:20)
            Text("Wireless · Encrypted · Yours")
                .font(.system(size:11)).foregroundStyle(.tertiary).padding(.bottom,18)
        }.frame(maxWidth:.infinity)
    }
    private func instruction(_ number:String,_ text:String) -> some View {
        HStack(spacing:12) { Text(number).font(.system(size:11,weight:.semibold)).foregroundStyle(.secondary).frame(width:22,height:22).background(Color.primary.opacity(0.06),in:Circle()); Text(text).font(.system(size:12)).foregroundStyle(.secondary) }
    }
    private var controls: some View {
        HStack(spacing:16) {
            Button { model.sendAction("back") } label: { Image(systemName:"chevron.left") }.help("Back · ⌘[")
            Button { model.sendAction("home") } label: { Image(systemName:"circle") }.help("Home · ⇧⌘H")
            Button { model.sendAction("recents") } label: { Image(systemName:"square.on.square") }.help("Recents · ⇧⌘R")
        }.buttonStyle(.plain).font(.system(size:16)).padding(.horizontal,20).padding(.vertical,12).background(.regularMaterial,in:Capsule()).disabled(!model.control)
    }
    private var pairing: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack { Text("Pair your Redmi").font(.title2.weight(.semibold)); Spacer(); Button { model.showPairing = false } label:{ Image(systemName:"xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            Text("On your phone, open the companion and choose Make phone available & pair, or Create pairing invitation. Share the invitation with this Mac, then paste it below.").font(.callout).foregroundStyle(.secondary)
            SecureField("Paste the pairing invitation",text:$model.invitationText).textFieldStyle(.roundedBorder)
            Label("The invitation contains your phone’s identity and a temporary pairing key. Share it only with a Mac you trust.",systemImage:"lock.shield").font(.caption).foregroundStyle(.secondary)
            if !model.invitationText.isEmpty { Text(model.state).font(.callout); Text(model.detail).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Cancel") { model.showPairing = false }; Button("Pair") { model.pair() }.buttonStyle(.borderedProminent).disabled(model.invitationText.isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:410)
    }
}

struct MirrorSettings: View {
    @ObservedObject var model: MirrorModel
    @AppStorage("autoConnect") private var autoConnect = true
    @AppStorage("playAudio") private var playAudio = true
    @AppStorage("receiveClipboard") private var receiveClipboard = false
    @AppStorage("quality") private var quality = "balanced"
    @StateObject private var ui = SettingsUIState()
    var body: some View {
        TabView {
            Form {
                Toggle("Connect automatically to paired Redmi",isOn:$autoConnect)
                Toggle("Play supported Android audio",isOn:$playAudio)
                Toggle("Receive clipboard shared by phone",isOn:$receiveClipboard)
                Text("Clipboard sharing is explicit. Android restricts background clipboard access.").font(.caption).foregroundStyle(.secondary)
                Picker("Streaming quality",selection:$quality) {
                    Text("Efficient · 30 fps").tag("efficient")
                    Text("Responsive · up to 60 fps").tag("responsive")
                    Text("Balanced · up to 60 fps").tag("balanced")
                    Text("More detail · up to 60 fps").tag("detail")
                }.onChange(of:quality) { model.setQuality() }
                Text("Responsive uses a smaller image to reduce phone and network load. Actual frame rate depends on the phone and Wi-Fi; bitrate adapts when the connection slows.").font(.caption).foregroundStyle(.secondary)
                if model.connected {
                    LabeledContent("Video",value:"\(model.media.width) × \(model.media.height)")
                    LabeledContent("Decode",value:String(format:"%.1f ms",model.media.decodeMilliseconds))
                    LabeledContent("Received",value:String(format:"%.1f Mb/s",model.megabits))
                }
            }.formStyle(.grouped).tabItem { Label("General",systemImage:"gearshape") }
            Form {
                if let device = model.current {
                    LabeledContent("Phone",value:device.name)
                    LabeledContent("Connection",value:"Certificate-pinned TLS")
                    Text("Device identity: \(device.fingerprint.prefix(16))…").font(.caption.monospaced()).foregroundStyle(.secondary)
                    TextField("Private network address",text:$ui.endpoint,prompt:Text(device.host))
                    Button("Save address and connect") { model.updateEndpoint(ui.endpoint) }.disabled(ui.endpoint.isEmpty)
                    Text("For different networks, enter a private VPN address or configure your own relay below. Both apps connect out to the relay; your phone’s inner session stays encrypted end to end. Internet deployment requires setup and remains unverified. Never expose ADB to the public Internet.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Remote relay").font(.headline)
                    TextField("Relay host",text:$ui.relayHost)
                    TextField("Port",text:$ui.relayPort)
                    TextField("Certificate SHA-256",text:$ui.relayFingerprint)
                    SecureField("Private room token",text:$ui.relayRoom)
                    Button("Save relay and connect") { model.configureRelay(host:ui.relayHost,port:ui.relayPort,fingerprint:ui.relayFingerprint,room:ui.relayRoom) }
                    if device.relay != nil { Button("Use local connection") { model.useLocalConnection() } }
                    Text("Use the same relay identity and room token in the phone companion. Keys are stored in Keychain.").font(.caption).foregroundStyle(.secondary)
                    Button("Forget this Redmi",role:.destructive) { ui.confirmUnpair = true }
                } else { Text("Pair a Redmi to manage its connection.").foregroundStyle(.secondary) }
                if !model.transferMessage.isEmpty { Text(model.transferMessage).font(.caption) }
            }.formStyle(.grouped).tabItem { Label("Pairing",systemImage:"lock.shield") }
        }.padding(12)
        .confirmationDialog("Forget this Redmi?",isPresented:$ui.confirmUnpair) { Button("Forget Redmi",role:.destructive) { model.unpair() } } message: { Text("This Mac’s saved pairing will be removed. If the phone is offline, revoke this Mac in the phone companion too.") }
    }
}

@MainActor final class WindowUIState: ObservableObject { @Published var hovering = false }
@MainActor final class SettingsUIState: ObservableObject { @Published var endpoint = ""; @Published var confirmUnpair = false; @Published var relayHost = ""; @Published var relayPort = "443"; @Published var relayFingerprint = ""; @Published var relayRoom = "" }
