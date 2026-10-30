import Foundation
import CryptoKit
import LibroxChapterWorker
import LibroxChatterbox

/// Immutable exact source/options CONTENT only. The current authenticated book
/// intent must name its digest before a Worker may use it. A blob never grants
/// inference or proves preparation/currentness/catalog availability.
package struct ChatterboxBookEntryContent: Sendable {
    package static let maximumBytes = 8 * 1024 * 1024
    package let scopeID: String
    package let chapterIndex: Int
    package let originalText: String
    package let entry: ChatterboxPreparedBookEntry
    private struct Wire: Codable {
        let version: Int
        let accountPartition, scopeID: String
        let chapterIndex: Int
        let originalText: String
        let request: ChapterRenderRequest?
        let plan: Data?
        let silentTextSHA256: String?
        let silentUTF16Length: Int?
    }
    private let wire: Wire
    package init(book: ChatterboxPreparedBookSubmission, chapterIndex: Int, originalText: String,
                 entry: ChatterboxPreparedBookEntry, session: ChapterAccountSession) throws {
        guard session.accountPartition == book.scope.accountPartition,
              book.scope.book.chapterKeys.indices.contains(chapterIndex), book.supportsCurrentPlanner,
              originalText.utf16.count <= 131072, originalText.utf8.count <= 393216 else {
            throw ChatterboxChapterRenderPlanError.invalidPlan
        }
        let wire: Wire
        switch entry {
        case .chapter(let prepared):
            guard prepared.submission.session == session,
                  Data(prepared.submission.originalText.utf8) == Data(originalText.utf8) else {
                throw ChatterboxChapterRenderPlanError.sourceMismatch
            }
            try book.validate(prepared, chapterIndex: chapterIndex)
            wire = Wire(version: 1, accountPartition: session.accountPartition, scopeID: book.scope.identifier,
                chapterIndex: chapterIndex, originalText: originalText, request: prepared.submission.request,
                plan: prepared.plan.encoded(), silentTextSHA256: nil, silentUTF16Length: nil)
        case .silent(let proof):
            guard proof.chapterIndex == chapterIndex,
                  case .silent(let expected) = try book.scope.book.classify(text: originalText, chapterIndex: chapterIndex),
                  proof == expected else { throw ChatterboxChapterRenderPlanError.sourceMismatch }
            try proof.validate(text: originalText)
            wire = Wire(version: 1, accountPartition: session.accountPartition, scopeID: book.scope.identifier,
                chapterIndex: chapterIndex, originalText: originalText, request: nil, plan: nil,
                silentTextSHA256: proof.textSHA256, silentUTF16Length: proof.utf16Length)
        }
        self.scopeID = wire.scopeID; self.chapterIndex = chapterIndex
        self.originalText = originalText; self.entry = entry; self.wire = wire
        _ = try encoded()
    }
    package func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(wire)
        guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw ChatterboxChapterRenderPlanError.budget }
        return bytes
    }
    package func sha256() throws -> String { Self.hash(try encoded()) }
    package func identity() throws -> ChapterBookEntryContentIdentity {
        let kind: ChapterBookEntryContentIdentity.Kind
        switch entry { case .chapter: kind = .chapter; case .silent: kind = .silent }
        return try .init(accountPartition: wire.accountPartition, scopeID: scopeID, chapterIndex: chapterIndex, kind: kind, payload: encoded())
    }
    package static func decode(_ bytes: Data, identity: ChapterBookEntryContentIdentity, book: ChatterboxPreparedBookSubmission,
                               chapterIndex: Int, session: ChapterAccountSession) throws -> Self {
        try identity.verify(bytes)
        guard identity.accountPartition == session.accountPartition, identity.scopeID == book.scope.identifier,
              identity.chapterIndex == chapterIndex else { throw ChatterboxChapterRenderPlanError.sourceMismatch }
        let value = try decode(bytes, expectedSHA256: identity.payloadSHA256, book: book, chapterIndex: chapterIndex, session: session)
        guard try value.identity() == identity else { throw ChatterboxChapterRenderPlanError.sourceMismatch }; return value
    }
    /// Rehydrates the pair under the RECEIVER's fresh session. No producer epoch,
    /// local source/plan reference, path, file handle or private conditioning bytes
    /// cross this boundary. Actual backend rebind is still mandatory for work.
    package static func decode(_ bytes: Data, expectedSHA256: String, book: ChatterboxPreparedBookSubmission,
                               chapterIndex: Int, session: ChapterAccountSession) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= maximumBytes, Self.hash(bytes) == expectedSHA256 else {
            throw ChatterboxChapterRenderPlanError.invalidPlan
        }
        let wire = try JSONDecoder().decode(Wire.self, from: bytes)
        guard wire.version == 1, wire.accountPartition == session.accountPartition,
              wire.scopeID == book.scope.identifier, wire.chapterIndex == chapterIndex else {
            throw ChatterboxChapterRenderPlanError.sourceMismatch
        }
        let entry: ChatterboxPreparedBookEntry
        if let request = wire.request {
            guard let planBytes = wire.plan, wire.silentTextSHA256 == nil, wire.silentUTF16Length == nil else {
                throw ChatterboxChapterRenderPlanError.invalidPlan
            }
            let submission = try ChapterSubmission(request: request, originalText: wire.originalText, session: session)
            let plan = try ChatterboxChapterRenderPlan.decode(planBytes, source: wire.originalText)
            entry = .chapter(ChatterboxPreparedChapterSubmission(submission: submission, plan: plan))
        } else {
            guard wire.plan == nil, let digest = wire.silentTextSHA256, let count = wire.silentUTF16Length,
                  case .silent(let proof) = try book.scope.book.classify(text: wire.originalText, chapterIndex: chapterIndex),
                  proof.textSHA256 == digest, proof.utf16Length == count else {
                throw ChatterboxChapterRenderPlanError.sourceMismatch
            }
            entry = .silent(proof)
        }
        let value = try Self(book: book, chapterIndex: chapterIndex, originalText: wire.originalText, entry: entry, session: session)
        guard try value.encoded() == bytes else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        return value
    }
    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
