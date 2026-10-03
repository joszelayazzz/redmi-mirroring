import Foundation
import Security

struct PairingInvitation: Codable, Equatable {
    let host: String
    let port: UInt16
    let id: String
    let name: String
    let fingerprint: String
    let secret: String
    init(link: String) throws {
        guard let url = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "redmimirror", url.host == "pair" else { throw MirrorError.invalidInvitation }
        let items = url.queryItems ?? []
        func value(_ key: String) throws -> String {
            let matches = items.filter { $0.name == key }
            guard matches.count == 1, let value = matches[0].value, !value.isEmpty else { throw MirrorError.invalidInvitation }
            return value
        }
        host = try value("host")
        guard host.count <= 253, !host.contains(where: { $0.isWhitespace || $0.isNewline }), !host.contains("/"), let parsedPort = UInt16(try value("port")), parsedPort > 0 else { throw MirrorError.invalidInvitation }
        port = parsedPort
        id = try value("id")
        guard UUID(uuidString: id) != nil else { throw MirrorError.invalidInvitation }
        name = String((try value("name")).prefix(128))
        fingerprint = try value("fp").lowercased()
        secret = try value("secret").lowercased()
        guard Self.validHex(fingerprint), Self.validHex(secret) else { throw MirrorError.invalidInvitation }
    }
    static func validHex(_ s: String) -> Bool { s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

struct RelayConfiguration: Codable, Equatable {
    var host: String
    var port: UInt16
    var fingerprint: String
    var room: String
}
struct PairedDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    var port: UInt16
    var fingerprint: String
    var secret: String
    var clientId: String
    var relay: RelayConfiguration?
    init(invitation: PairingInvitation, clientId: String) {
        id = invitation.id; name = invitation.name; host = invitation.host; port = invitation.port
        fingerprint = invitation.fingerprint; secret = invitation.secret; self.clientId = clientId
    }
}

enum MirrorError: LocalizedError {
    case invalidInvitation, invalidFrame, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "This invitation is incomplete or invalid. Share a fresh invitation from the phone."
        case .invalidFrame: return "The device sent an invalid frame. The connection was closed."
        case .keychain(let code): return "Keychain could not save your pairing (\(code))."
        }
    }
}

struct WireFrame { let type: UInt8; let payload: Data }
struct FrameParser {
    static let maximum = 16 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [WireFrame] {
        // Receive chunks are capped at 256 KiB. A complete frame cannot exceed the hard limit.
        guard data.count <= Self.maximum + 4 else { throw MirrorError.invalidFrame }
        buffer.append(data)
        var result = [WireFrame]()
        var offset = 0
        while buffer.count - offset >= 4 {
            let size = (0..<4).reduce(0) { ($0 << 8) | Int(buffer[buffer.startIndex + offset + $1]) }
            guard size >= 1, size <= Self.maximum else { buffer.removeAll(); throw MirrorError.invalidFrame }
            guard buffer.count - offset >= size + 4 else { break }
            let type = buffer[buffer.startIndex + offset + 4]
            let start = buffer.startIndex + offset + 5
            result.append(WireFrame(type: type, payload: buffer.subdata(in: start..<(start + size - 1))))
            offset += 4 + size
        }
        if offset > 0 { buffer.removeFirst(offset) }
        guard buffer.count <= Self.maximum + 4 else { buffer.removeAll(); throw MirrorError.invalidFrame }
        return result
    }
    static func encode(type: UInt8, payload: Data) -> Data {
        precondition(payload.count < maximum)
        let length = UInt32(payload.count + 1)
        var result = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255), type])
        result.append(payload)
        return result
    }
}

final class PairingStore {
    private let service = "com.redmimirroring.pairing.v1"
    private let account = "pairedDevices"
    func load() throws -> [PairedDevice] {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data else { throw MirrorError.keychain(status) }
        return try JSONDecoder().decode([PairedDevice].self, from: data)
    }
    func save(_ devices: [PairedDevice]) throws {
        let data = try JSONEncoder().encode(devices)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = base
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw MirrorError.keychain(added) }
        } else if status != errSecSuccess { throw MirrorError.keychain(status) }
    }
    private var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
}
