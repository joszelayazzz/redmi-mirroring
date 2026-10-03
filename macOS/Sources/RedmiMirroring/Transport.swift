import Foundation
import Network
import CryptoKit
import Security

final class SecureTransport {
    var onFrame: ((WireFrame) -> Void)?
    var onState: ((String) -> Void)?
    var onFailure: ((String, Bool) -> Void)?
    // Main-queue delivery is separate from socket arrival and codec time. Keep diagnostics
    // on the same actor as their consumer, without publishing at video frame rate.
    @MainActor private(set) var videoDeliveryMilliseconds = 0.0
    @MainActor private(set) var maximumVideoDeliveryMilliseconds = 0.0
    private let queue = DispatchQueue(label: "com.redmimirroring.transport", qos: .userInteractive)
    private var connection: NWConnection?
    private var parser = FrameParser()
    private var generation = UUID()
    private var pinRejected = false
    private var fileTransferActive = false
    private let epochLock = NSLock()
    private var deliveryEpoch = UUID()
    private var activeDeliveryEpoch = UUID()
    private func advanceEpoch() -> UUID { epochLock.lock(); defer { epochLock.unlock() }; deliveryEpoch = UUID(); return deliveryEpoch }
    private func matchesEpoch(_ expected: UUID) -> Bool { epochLock.lock(); defer { epochLock.unlock() }; return deliveryEpoch == expected }

    func connect(device: PairedDevice, endpoint: NWEndpoint? = nil, pairing: Bool) {
        let delivery = advanceEpoch()
        resetDeliveryMetrics(epoch: delivery)
        queue.async { [weak self] in
            guard let self else { return }
            self.activeDeliveryEpoch = delivery
            self.connection?.cancel()
            self.parser = FrameParser(); self.pinRejected = false
            let generation = UUID(); self.generation = generation
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
                guard let self, self.generation == generation else { complete(false); return }
                let ref = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certificates = SecTrustCopyCertificateChain(ref) as? [SecCertificate], let leaf = certificates.first else { self.pinRejected = true; complete(false); return }
                let bytes = SecCertificateCopyData(leaf) as Data
                let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                let matches = fingerprint == device.fingerprint
                self.pinRejected = !matches
                complete(matches)
            }, self.queue)
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true; tcp.keepaliveIdle = 10; tcp.keepaliveInterval = 5; tcp.keepaliveCount = 3
            let parameters = NWParameters(tls: tls, tcp: tcp)
            let destination = endpoint ?? .hostPort(host: NWEndpoint.Host(device.host), port: NWEndpoint.Port(rawValue: device.port)!)
            let conn = NWConnection(to: destination, using: parameters)
            self.connection = conn
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                guard let self, let conn, self.generation == generation else { return }
                switch state {
                case .ready:
                    self.emitState("Authenticating")
                    self.sendJSONLocked(["type": "auth", "version": 1, "clientId": device.clientId, "name": Host.current().localizedName ?? "Mac", "secret": device.secret, "pair": pairing], conn: conn)
                    self.receive(conn, generation: generation)
                case .preparing: self.emitState("Connecting securely")
                case .waiting(let error): self.fail(error.localizedDescription, fatal: self.pinRejected)
                case .failed(let error): self.fail(self.pinRejected ? "Device identity does not match the invitation. Connection refused." : error.localizedDescription, fatal: self.pinRejected)
                default: break
                }
            }
            conn.start(queue: self.queue)
        }
    }
    func disconnect() {
        let delivery = advanceEpoch()
        resetDeliveryMetrics(epoch: delivery)
        queue.async { [weak self] in
            self?.generation = UUID()
            self?.connection?.cancel(); self?.connection = nil; self?.parser = FrameParser(); self?.fileTransferActive = false
        }
    }
    func send(_ json: [String: Any]) { queue.async { [weak self] in guard let self, let conn = self.connection else { return }; self.sendJSONLocked(json, conn: conn) } }
    private func sendJSONLocked(_ json: [String: Any], conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: json), data.count < FrameParser.maximum else { return }
        conn.send(content: FrameParser.encode(type: 1, payload: data), completion: .contentProcessed { [weak self] error in
            if let error, self?.connection === conn { self?.fail(error.localizedDescription, fatal: false) }
        })
    }
    func sendFile(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let conn = self.connection else { return }
            guard !self.fileTransferActive else {
                DispatchQueue.main.async { completion(.failure(NSError(domain:"Transfer",code:4,userInfo:[NSLocalizedDescriptionKey:"Wait for the current file to finish sending."]))) }; return
            }
            self.fileTransferActive = true
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 32 * 1024 * 1024 else { throw NSError(domain: "Transfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a regular file between 1 byte and 32 MB."]) }
                let handle = try FileHandle(forReadingFrom: url)
                let id = UUID().uuidString
                self.sendJSONLocked(["type":"fileStart", "id":id, "name":url.lastPathComponent, "size":size], conn: conn)
                self.sendFileChunk(handle, id: id, conn: conn, remaining: size, completion: completion)
            } catch { self.fileTransferActive = false; DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    private func sendFileChunk(_ handle: FileHandle, id: String, conn: NWConnection, remaining: Int, completion: @escaping (Result<String, Error>) -> Void) {
        do {
            guard self.connection === conn else { throw NSError(domain: "Transfer", code: 2, userInfo: [NSLocalizedDescriptionKey:"Connection interrupted."]) }
            if remaining == 0 { self.fileTransferActive = false; try? handle.close(); self.sendJSONLocked(["type":"fileEnd", "id":id], conn: conn); DispatchQueue.main.async { completion(.success("Sent. Waiting for phone confirmation…")) }; return }
            guard let chunk = try handle.read(upToCount: min(65536, remaining)), !chunk.isEmpty else { throw NSError(domain:"Transfer", code:3, userInfo:[NSLocalizedDescriptionKey:"File changed during transfer."]) }
            conn.send(content: FrameParser.encode(type: 5, payload: chunk), completion: .contentProcessed { [weak self] error in
                guard let self else { try? handle.close(); return }
                if let error { self.fileTransferActive = false; try? handle.close(); DispatchQueue.main.async { completion(.failure(error)) }; return }
                self.sendFileChunk(handle, id: id, conn: conn, remaining: remaining - chunk.count, completion: completion)
            })
        } catch { fileTransferActive = false; try? handle.close(); DispatchQueue.main.async { completion(.failure(error)) } }
    }
    private func receive(_ conn: NWConnection, generation: UUID) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.generation == generation else { return }
            do {
                if let data {
                    let delivery = self.activeDeliveryEpoch
                    for frame in try self.parser.append(data) {
                        let queuedAt = DispatchTime.now().uptimeNanoseconds
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.matchesEpoch(delivery) else { return }
                            if frame.type == 3 {
                                let queueWait = Double(DispatchTime.now().uptimeNanoseconds - queuedAt) / 1_000_000
                                self.videoDeliveryMilliseconds = queueWait
                                self.maximumVideoDeliveryMilliseconds = max(self.maximumVideoDeliveryMilliseconds, queueWait)
                            }
                            self.onFrame?(frame)
                        }
                    }
                }
            } catch { self.fail(error.localizedDescription, fatal: true); return }
            if let error { self.fail(error.localizedDescription, fatal: false); return }
            if complete { self.fail("The phone disconnected.", fatal: false); return }
            self.receive(conn, generation: generation)
        }
    }
    private func resetDeliveryMetrics(epoch: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.matchesEpoch(epoch) else { return }
            self.videoDeliveryMilliseconds = 0
            self.maximumVideoDeliveryMilliseconds = 0
        }
    }
    private func emitState(_ state: String) {
        let expected = generation
        let delivery = activeDeliveryEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.matchesEpoch(delivery), self.queue.sync(execute:{ self.generation == expected }) else { return }
            self.onState?(state)
        }
    }
    private func fail(_ reason: String, fatal: Bool) {
        generation = UUID(); connection?.cancel(); connection = nil
        let expected = generation
        let delivery = activeDeliveryEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.matchesEpoch(delivery), self.queue.sync(execute:{ self.generation == expected }) else { return }
            self.onFailure?(reason, fatal)
        }
    }
}
