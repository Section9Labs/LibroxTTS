import Foundation
import CryptoKit

/// Current DEVICE preparation data. No Play/Pause or media-ready bit exists.
/// A wanted member names the confirmed complete-policy/read-set content; a
/// cancellation needs no new asset transfer and removes only this device's want.
struct ChapterBookCloudDevice: Codable, Sendable, Equatable {
    let version: Int
    let intent: ChapterBookDemandIntent
    let readSet: ChapterBookReadSetIdentity?
    func validate(account: String, scope: String, device: UUID) throws {
        guard version == 1, isDigest(account), isDigest(scope), intent.accountPartition == account,
              intent.scopeID == scope, intent.deviceID == device, intent.revision > 0,
              intent.wantedRevision > 0, intent.wantedRevision <= intent.revision,
              (0..<4096).contains(intent.priority.chapterIndex), (0...131072).contains(intent.priority.sourceUTF16Offset) else {
            throw ChapterDemandTransportError.invalidRecord
        }
        if intent.wanted {
            guard let readSet else { throw ChapterDemandTransportError.invalidRecord }
            try readSet.validate()
            guard readSet.accountPartition == account, readSet.scopeID == scope, readSet.deviceID == device,
                  readSet.revision == intent.revision else { throw ChapterDemandTransportError.invalidRecord }
        } else if readSet != nil { throw ChapterDemandTransportError.invalidRecord }
    }
}

/// Every device mutation CASes this root too, so a future Worker transaction can
/// fence membership additions/cancellations instead of trusting a query result.
/// Entries/tombstones are retained; revision is NOT a clock or a lease.
struct ChapterBookCloudRoot: Codable, Sendable, Equatable {
    static let maximumDevices = 32
    let version: Int
    let accountPartition, scopeID: String
    let revision: UInt64
    var members: [String: String]
    func validate(account: String, scope: String) throws {
        guard version == 1, isDigest(account), isDigest(scope), accountPartition == account, scopeID == scope,
              revision > 0, (1...Self.maximumDevices).contains(members.count),
              members.allSatisfy({ UUID(uuidString: $0.key)?.uuidString.lowercased() == $0.key && isDigest($0.value) }) else {
            throw ChapterDemandTransportError.invalidRecord
        }
    }
}
struct ChapterBookCloudProposal: Sendable {
    let root: ChapterBookCloudRoot
    let device: ChapterBookCloudDevice
    let changed: Bool
}
enum ChapterBookCloudControl {
    static let maximumPayloadBytes = 16 * 1024
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard !bytes.isEmpty, bytes.count <= maximumPayloadBytes else { throw ChapterDemandTransportError.quotaExceeded }; return bytes
    }
    static func decode<T: Codable>(_ type: T.Type, _ bytes: Data) throws -> T {
        guard !bytes.isEmpty, bytes.count <= maximumPayloadBytes else { throw ChapterDemandTransportError.invalidRecord }
        let value = try JSONDecoder().decode(type, from: bytes)
        guard try encode(value) == bytes else { throw ChapterDemandTransportError.invalidRecord }; return value
    }
    static func digest(_ value: ChapterBookCloudDevice) throws -> String {
        SHA256.hash(data: try encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func proposal(_ desired: ChapterBookCloudDevice, root: ChapterBookCloudRoot?, device: ChapterBookCloudDevice?) throws -> ChapterBookCloudProposal {
        let intent = desired.intent, key = intent.deviceID.uuidString.lowercased()
        try desired.validate(account: intent.accountPartition, scope: intent.scopeID, device: intent.deviceID)
        if let root {
            try root.validate(account: intent.accountPartition, scope: intent.scopeID)
            if let device {
                try device.validate(account: intent.accountPartition, scope: intent.scopeID, device: intent.deviceID)
                guard root.members[key] == (try digest(device)) else { throw ChapterDemandTransportError.inconsistentSnapshot }
                guard intent.revision >= device.intent.revision else { throw ChapterDemandTransportError.remoteRevisionAhead }
                if intent.revision == device.intent.revision {
                    guard desired == device else { throw ChapterDemandTransportError.conflict }
                    return .init(root: root, device: device, changed: false)
                }
                guard intent.wantedRevision >= device.intent.wantedRevision,
                      intent.wantedRevision - device.intent.wantedRevision <= intent.revision - device.intent.revision,
                      (intent.wantedRevision - device.intent.wantedRevision) % 2 == (intent.wanted == device.intent.wanted ? 0 : 1) else {
                    throw ChapterDemandTransportError.invalidRecord
                }
            } else {
                guard root.members[key] == nil else { throw ChapterDemandTransportError.inconsistentSnapshot }
                guard root.members.count < ChapterBookCloudRoot.maximumDevices else { throw ChapterDemandTransportError.quotaExceeded }
            }
            guard root.revision < .max else { throw ChapterDemandTransportError.quotaExceeded }
            var members = root.members; members[key] = try digest(desired)
            return .init(root: .init(version: 1, accountPartition: root.accountPartition, scopeID: root.scopeID,
                revision: root.revision + 1, members: members), device: desired, changed: true)
        }
        guard device == nil else { throw ChapterDemandTransportError.inconsistentSnapshot }
        return .init(root: .init(version: 1, accountPartition: intent.accountPartition, scopeID: intent.scopeID,
            revision: 1, members: [key: try digest(desired)]), device: desired, changed: true)
    }
}
