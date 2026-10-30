import Foundation
import CryptoKit

/// Exact SDK-authored book policy bytes plus the original Reader spine. Not a
/// demand or inference grant. Planning restores/validates actual typed settings;
/// no consumer is allowed to reconstruct them from this scope's digest.
public struct ChapterBookPreparationScope: Sendable, Equatable {
    public let book: ChapterBookSource
    public let accountPartition: String
    public let identifier: String
    package let configuration: Data
    private struct Wire: Codable {
        let version: Int
        let accountPartition: String
        let book: ChapterBookSource
        let configuration: Data
    }
    package init(book: ChapterBookSource, accountPartition: String, configuration: Data) throws {
        try book.validate()
        guard isDigest(accountPartition), !configuration.isEmpty, configuration.count <= 65536 else { throw ChapterWorkerError.invalidIdentity }
        self.book = book; self.accountPartition = accountPartition; self.configuration = configuration
        let data = try Self.encode(Wire(version: 1, accountPartition: accountPartition, book: book, configuration: configuration))
        guard data.count <= 4 * 1024 * 1024 else { throw ChapterOutboxError.budgetExceeded }
        identifier = Self.hash(data)
    }
    package func encoded() throws -> Data {
        try Self.encode(Wire(version: 1, accountPartition: accountPartition, book: book, configuration: configuration))
    }
    package static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw ChapterOutboxError.budgetExceeded }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard wire.version == 1 else { throw ChapterWorkerError.invalidIdentity }
        let value = try Self(book: wire.book, accountPartition: wire.accountPartition, configuration: wire.configuration)
        guard try value.encoded() == data else { throw ChapterWorkerError.invalidIdentity }
        return value
    }
    package func validate(_ request: ChapterRenderRequest, chapterIndex: Int) throws {
        try request.validate()
        guard request.accountPartition == accountPartition, book.chapterKeys.indices.contains(chapterIndex),
              request.source.utf16Length <= 131072,
              request.source.bookSHA256 == book.bookSHA256,
              Data(request.source.extractionRevision.utf8) == Data(book.extractionRevision.utf8),
              Data(request.source.chapterKey.utf8) == Data(book.chapterKeys[chapterIndex].utf8)
        else { throw ChapterWorkerError.invalidIdentity }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func hash(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
}

public struct ChapterBookPriority: Codable, Sendable, Equatable {
    public let chapterIndex, sourceUTF16Offset: Int
    public init(chapterIndex: Int, sourceUTF16Offset: Int) throws {
        guard (0..<4096).contains(chapterIndex), (0...131072).contains(sourceUTF16Offset) else { throw ChapterWorkerError.invalidIdentity }
        self.chapterIndex = chapterIndex; self.sourceUTF16Offset = sourceUTF16Offset
    }
}

/// Per-device durable preparation intent. No Play/Pause bit exists. revision
/// includes source admission/priority; wantedRevision changes only on wanted
/// transitions. A seek need not throw away in-flight exact audible work.
public struct ChapterBookDemandIntent: Codable, Sendable, Equatable {
    public let scopeID: String
    public let accountPartition: String
    public let deviceID: UUID
    public let revision, wantedRevision: UInt64
    public let wanted: Bool
    public let priority: ChapterBookPriority
}

public struct ChapterBookStoredChapter: Codable, Sendable, Equatable {
    public let chapterIndex: Int
    public let request: ChapterRenderRequest?
    public let sourceReference: ChapterLocalSourceReference?
    public let renderPlanReference: ChapterLocalRenderPlanReference?
    public let silentTextSHA256: String?
    public let silentUTF16Length: Int?
    /// Reader's durable exact upload content, never a current cloud grant.
    package var contentIdentity: ChapterBookEntryContentIdentity? = nil
    package var contentServerRevision: String? = nil
    package func validate(scope: ChapterBookPreparationScope) throws {
        guard scope.book.chapterKeys.indices.contains(chapterIndex) else { throw ChapterWorkerError.invalidIdentity }
        if let request {
            try scope.validate(request, chapterIndex: chapterIndex)
            guard sourceReference != nil, renderPlanReference != nil, silentTextSHA256 == nil, silentUTF16Length == nil else {
                throw ChapterWorkerError.invalidIdentity
            }
        } else {
            guard sourceReference == nil, renderPlanReference == nil, silentTextSHA256.map(isDigest) == true,
                  let count = silentUTF16Length, (0...131072).contains(count) else { throw ChapterWorkerError.invalidIdentity }
            if count == 0, silentTextSHA256 != SHA256.hash(data: Data()).map({ String(format: "%02x", $0) }).joined() {
                throw ChapterWorkerError.invalidIdentity
            }
        }
        if let identity = contentIdentity {
            try identity.validate()
            guard identity.accountPartition == scope.accountPartition, identity.scopeID == scope.identifier,
                  identity.chapterIndex == chapterIndex, identity.kind == (request == nil ? .silent : .chapter) else {
                throw ChapterWorkerError.invalidIdentity
            }
            if let revision = contentServerRevision { _ = try ChapterServerRevision(opaqueValue: revision) }
        } else if contentServerRevision != nil { throw ChapterWorkerError.invalidIdentity }
    }
}

/// A local journal observation, NOT a server receipt or work/playback grant.
public struct ChapterBookStoredPreparation: Sendable {
    public let scope: ChapterBookPreparationScope
    public let intent: ChapterBookDemandIntent
    public let chapters: [ChapterBookStoredChapter]
    public let pending: Bool
    public let confirmedServerRevision: ChapterServerRevision?
}

/// Live Reader-only optimistic token; never serialized or sent to the Worker.
package struct ChapterBookAdmission: Sendable {
    let owner, command: UUID
    let scopeID: String
    let wantedRevision: UInt64
    let chapterIndex: Int
    package let prior: ChapterBookStoredChapter?
}

/// Atomic Reader snapshot for ONE pending content transfer, not a Worker claim.
package struct ChapterBookPendingContentUpload: Sendable {
    package let scope: ChapterBookPreparationScope
    package let intent: ChapterBookDemandIntent
    package let chapter: ChapterBookStoredChapter
}
