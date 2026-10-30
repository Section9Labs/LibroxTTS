import Foundation
import CryptoKit

/// Portable desired entry metadata; local file/journal references and content
/// acknowledgement tags are deliberately absent. Full options live in the
/// exact referenced entry content, not defaults inferred from these hashes.
package struct ChapterBookReadSetEntry: Codable, Sendable, Equatable {
    package let chapterIndex: Int
    package let kind: ChapterBookEntryContentIdentity.Kind
    package let renderKey: String?
    package let textSHA256: String
    package let utf16Length: Int
    package let content: ChapterBookEntryContentIdentity?
    package init(_ stored: ChapterBookStoredChapter, scope: ChapterBookPreparationScope) throws {
        try stored.validate(scope: scope)
        chapterIndex = stored.chapterIndex; content = stored.contentIdentity
        if let request = stored.request {
            kind = .chapter; renderKey = try request.renderKey()
            textSHA256 = request.source.textSHA256; utf16Length = request.source.utf16Length
        } else {
            guard let hash = stored.silentTextSHA256, let count = stored.silentUTF16Length else { throw ChapterWorkerError.invalidIdentity }
            kind = .silent; renderKey = nil; textSHA256 = hash; utf16Length = count
        }
        try validate(scope: scope)
    }
    package func validate(scope: ChapterBookPreparationScope) throws {
        guard scope.book.chapterKeys.indices.contains(chapterIndex), isDigest(textSHA256), (0...131072).contains(utf16Length),
              kind == .chapter ? (renderKey.map(isDigest) == true && utf16Length > 0) : renderKey == nil else {
            throw ChapterWorkerError.invalidIdentity
        }
        if utf16Length == 0 {
            guard kind == .silent, textSHA256 == Self.hash(Data()) else { throw ChapterWorkerError.invalidIdentity }
        }
        if let content {
            try content.validate()
            guard content.accountPartition == scope.accountPartition, content.scopeID == scope.identifier,
                  content.chapterIndex == chapterIndex, content.kind == kind else { throw ChapterWorkerError.invalidIdentity }
        }
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Immutable FULL book policy/spine plus exact current desired-entry read set.
/// CONTENT ONLY. Its existence/snapshot counters authorize no work/playback.
package struct ChapterBookReadSet: Sendable {
    package static let maximumBytes = 12 * 1024 * 1024
    package let scope: ChapterBookPreparationScope
    package let intent: ChapterBookDemandIntent
    package let entries: [ChapterBookReadSetEntry]
    private struct Wire: Codable {
        let version: Int
        let scope: Data
        let intent: ChapterBookDemandIntent
        let entries: [ChapterBookReadSetEntry]
    }
    package init(_ snapshot: ChapterBookStoredPreparation) throws {
        scope = snapshot.scope; intent = snapshot.intent
        entries = try snapshot.chapters.map { try ChapterBookReadSetEntry($0, scope: snapshot.scope) }
        try validate(); _ = try encoded()
    }
    private init(scope: ChapterBookPreparationScope, intent: ChapterBookDemandIntent, entries: [ChapterBookReadSetEntry]) throws {
        self.scope = scope; self.intent = intent; self.entries = entries; try validate()
    }
    private func validate() throws {
        guard try ChapterBookPreparationScope.decode(scope.encoded()) == scope,
              intent.scopeID == scope.identifier, intent.accountPartition == scope.accountPartition,
              intent.revision > 0, intent.wantedRevision > 0, intent.wantedRevision <= intent.revision,
              scope.book.chapterKeys.indices.contains(intent.priority.chapterIndex), (0...131072).contains(intent.priority.sourceUTF16Offset),
              entries.count <= scope.book.chapterKeys.count else { throw ChapterWorkerError.invalidIdentity }
        var last = -1
        for entry in entries {
            guard entry.chapterIndex > last else { throw ChapterWorkerError.invalidIdentity }
            try entry.validate(scope: scope); last = entry.chapterIndex
            if intent.priority.chapterIndex == entry.chapterIndex {
                guard intent.priority.sourceUTF16Offset <= entry.utf16Length else { throw ChapterWorkerError.invalidIdentity }
            }
        }
    }
    package func encoded() throws -> Data {
        try validate()
        let data = try Self.encode(Wire(version: 1, scope: scope.encoded(), intent: intent, entries: entries))
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw ChapterOutboxError.budgetExceeded }; return data
    }
    package func sha256() throws -> String { Self.hash(try encoded()) }
    package static func decode(_ data: Data, expectedSHA256: String, accountPartition: String,
                               scopeID: String, deviceID: UUID) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes, isDigest(expectedSHA256), Self.hash(data) == expectedSHA256 else {
            throw ChapterWorkerError.invalidIdentity
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == 1 else { throw ChapterWorkerError.invalidIdentity }
        let scope = try ChapterBookPreparationScope.decode(wire.scope)
        let value = try Self(scope: scope, intent: wire.intent, entries: wire.entries)
        guard value.scope.accountPartition == accountPartition, value.scope.identifier == scopeID,
              value.intent.deviceID == deviceID, try value.encoded() == data else { throw ChapterWorkerError.accountMismatch }
        return value
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return try encoder.encode(value)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Asset identity admitted from a SEPARATE current native intent transaction.
/// Revision counters here are logical metadata, not a clock, claim or lease.
package struct ChapterBookReadSetIdentity: Codable, Sendable, Equatable {
    package let version: Int
    package let accountPartition, scopeID: String
    package let deviceID: UUID
    package let revision: UInt64
    package let payloadSHA256: String
    package let byteCount: Int64
    package init(_ value: ChapterBookReadSet) throws {
        version = 1; accountPartition = value.scope.accountPartition; scopeID = value.scope.identifier
        deviceID = value.intent.deviceID; revision = value.intent.revision
        let bytes = try value.encoded(); byteCount = Int64(bytes.count); payloadSHA256 = try value.sha256(); try validate()
    }
    package func validate() throws {
        guard version == 1, isDigest(accountPartition), isDigest(scopeID), revision > 0, isDigest(payloadSHA256),
              (1...Int64(ChapterBookReadSet.maximumBytes)).contains(byteCount) else { throw ChapterWorkerError.invalidIdentity }
    }
    package func encoded() throws -> Data {
        try validate(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self); guard data.count <= 4096 else { throw ChapterWorkerError.invalidIdentity }; return data
    }
    package func key() throws -> String { "brs-" + SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined() }
    package static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4096 else { throw ChapterWorkerError.invalidIdentity }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard try value.encoded() == data else { throw ChapterWorkerError.invalidIdentity }; return value
    }
    package func decodeContent(_ bytes: Data) throws -> ChapterBookReadSet {
        try validate()
        guard bytes.count == byteCount else { throw ChapterWorkerError.invalidIdentity }
        let value = try ChapterBookReadSet.decode(bytes, expectedSHA256: payloadSHA256, accountPartition: accountPartition,
            scopeID: scopeID, deviceID: deviceID)
        guard value.intent.revision == revision else { throw ChapterWorkerError.invalidIdentity }; return value
    }
}
