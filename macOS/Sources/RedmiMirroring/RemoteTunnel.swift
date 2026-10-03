import Foundation
import Network
import CryptoKit
import Security

/// A loopback bridge. SecureTransport still establishes its independently
/// pinned Android TLS session through this byte tunnel; the relay cannot decode it.
@MainActor final class NativeRemoteTunnel {
    private var core: RemoteTunnelCore?
    private var epoch = UUID()

    deinit { core?.stop() }

    func start(host: String, port: UInt16, fingerprint: String, room: String,
               onReady: @escaping (UInt16) -> Void, onFailure: @escaping (String) -> Void) {
        stop()
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = fingerprint.lowercased().replacingOccurrences(of: ":", with: "")
        guard !host.isEmpty, host.count <= 253, !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"), port > 0,
              fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              room.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            onFailure("Enter the relay host, port, certificate fingerprint, and a 256-bit room token.")
            return
        }
        let token = epoch
        let worker = RemoteTunnelCore(host: host, port: port, fingerprint: fingerprint, room: room)
        worker.onReady = { [weak self] port in
            DispatchQueue.main.async { guard self?.epoch == token else { return }; onReady(port) }
        }
        worker.onFailure = { [weak self] message in
            DispatchQueue.main.async { guard self?.epoch == token else { return }; onFailure(message) }
        }
        core = worker
        worker.start()
    }

    func stop() {
        epoch = UUID()
        core?.stop()
        core = nil
    }
}

private final class RemoteTunnelCore {
    var onReady: ((UInt16) -> Void)?
    var onFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.redmimirroring.remote-tunnel", qos: .userInitiated)
    private let host: String
    private let port: UInt16
    private let fingerprint: String
    private let room: String
    private var listener: NWListener?
    private var outer: NWConnection?
    private var local: NWConnection?
    private var loopbackPort: UInt16?
    private var running = false
    private var admitted = false
    private var pinRejected = false
    private var session = UUID()
    private var attempt = 0
    private var retry: DispatchWorkItem?
    private var deadline: DispatchWorkItem?

    init(host: String, port: UInt16, fingerprint: String, room: String) {
        self.host = host; self.port = port; self.fingerprint = fingerprint; self.room = room
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = true
            do {
                let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.running, self.admitted, self.local == nil else {
                        connection.cancel(); return
                    }
                    self.local = connection
                    let session = self.session
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        guard let self, let connection, self.session == session, self.local === connection else { return }
                        switch state {
                        case .ready:
                            guard let outer = self.outer else { self.end("Relay disconnected."); return }
                            self.pump(connection, to: outer, session: session)
                            self.pump(outer, to: connection, session: session)
                        case .failed: self.end("The encrypted phone session disconnected.")
                        default: break
                        }
                    }
                    connection.start(queue: self.queue)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.running, self.listener === listener else { return }
                    switch state {
                    case .ready: self.loopbackPort = listener.port?.rawValue; self.connectRelay()
                    case .failed: self.end("Could not create the private loopback bridge.", fatal: true)
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            } catch { self.end("Could not create the private loopback bridge.", fatal: true) }
        }
    }

    func stop() {
        queue.async { [self] in
            self.running = false; self.session = UUID()
            self.retry?.cancel(); self.deadline?.cancel()
            self.outer?.cancel(); self.local?.cancel(); self.listener?.cancel()
            self.outer = nil; self.local = nil; self.listener = nil
            self.onReady = nil; self.onFailure = nil
        }
    }

    private func connectRelay() {
        guard running else { return }
        retry?.cancel(); retry = nil
        let session = UUID(); self.session = session
        admitted = false; pinRejected = false
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
            guard let self, self.session == session else { complete(false); return }
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(reference) as? [SecCertificate],
                  let leaf = chain.first else { self.pinRejected = true; complete(false); return }
            let actual = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map { String(format: "%02x", $0) }.joined()
            let matches = actual == self.fingerprint
            self.pinRejected = !matches
            complete(matches)
        }, queue)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 15; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: tls, tcp: tcp))
        outer = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.running, self.session == session else { return }
            switch state {
            case .ready:
                guard let payload = try? JSONSerialization.data(withJSONObject: ["role": "mac", "room": self.room]) else {
                    self.end("Could not prepare relay admission.", fatal: true); return
                }
                var packet = Data()
                let length = UInt32(payload.count)
                packet.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
                packet.append(payload)
                connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
                    guard let self, let connection, self.session == session else { return }
                    if error != nil { self.end("Could not reach the remote relay."); return }
                    self.readAdmissionHeader(connection, session: session)
                })
            case .failed, .waiting:
                self.end(self.pinRejected ? "The relay certificate does not match. Remote connection refused." : "Remote relay unavailable. Reconnecting…", fatal: self.pinRejected)
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.session == session, !self.admitted else { return }
            self.end("The relay is waiting for your phone. Reconnecting…")
        }
        deadline = timeout
        queue.asyncAfter(deadline: .now() + 125, execute: timeout)
        connection.start(queue: queue)
    }

    private func readAdmissionHeader(_ connection: NWConnection, session: UUID) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, complete, error in
            guard let self, self.session == session else { return }
            guard error == nil, !complete, let data, data.count == 4 else { self.end("Relay admission disconnected."); return }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard length >= 2, length <= 4096 else { self.end("Invalid relay admission response.", fatal: true); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, complete, error in
                guard let self, self.session == session else { return }
                guard error == nil, let body, body.count == length,
                      let response = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    self.end("Relay admission disconnected."); return
                }
                guard response["ok"] as? Bool == true else {
                    let reason = (response["error"] as? String ?? "Relay refused this room.").prefix(160)
                    let retryable = reason.contains("timed out") || reason.contains("capacity") || reason.contains("role") || reason.contains("rate")
                    self.end(String(reason), fatal: !retryable); return
                }
                guard !complete, let port = self.loopbackPort else { self.end("Relay connection closed."); return }
                self.deadline?.cancel(); self.deadline = nil
                self.admitted = true; self.attempt = 0
                self.onReady?(port)
                // A newly admitted relay is only useful if the app promptly
                // opens its inner TLS session. Bound idle rendezvous resources.
                let idle = DispatchWorkItem { [weak self] in
                    guard let self, self.session == session, self.local == nil else { return }
                    self.end("The remote session was not opened. Reconnecting…")
                }
                self.deadline = idle
                self.queue.asyncAfter(deadline: .now() + 30, execute: idle)
            }
        }
    }

    private func pump(_ source: NWConnection, to destination: NWConnection, session: UUID) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.running, self.session == session else { return }
            guard error == nil, let data, !data.isEmpty else { self.end("Remote connection interrupted. Reconnecting…"); return }
            destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                guard let self, self.session == session else { return }
                if sendError != nil || complete { self.end("Remote connection interrupted. Reconnecting…"); return }
                self.pump(source, to: destination, session: session)
            })
        }
    }

    private func end(_ message: String, fatal: Bool = false) {
        guard running else { return }
        session = UUID(); admitted = false
        deadline?.cancel(); deadline = nil
        outer?.cancel(); local?.cancel(); outer = nil; local = nil
        onFailure?(message)
        if fatal {
            running = false; retry?.cancel(); listener?.cancel(); listener = nil
            return
        }
        attempt += 1
        let wait = min(20.0, pow(2.0, Double(min(attempt, 4))))
        let item = DispatchWorkItem { [weak self] in self?.connectRelay() }
        retry?.cancel(); retry = item
        queue.asyncAfter(deadline: .now() + wait, execute: item)
    }
}
