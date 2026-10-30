import Foundation
import LibroxChapterWorker

/// Pure typed validation of immutable desired state. Actual current member
/// admission, stock-backend rebind and generation fences remain separate.
package struct ChatterboxPreparedBookReadSet: Sendable {
    package let metadata: ChapterBookReadSet
    package let book: ChatterboxPreparedBookSubmission
    package init(_ metadata: ChapterBookReadSet, session: ChapterAccountSession) throws {
        guard metadata.scope.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        self.metadata = metadata
        book = try ChatterboxPreparedBookSubmission.restore(scope: metadata.scope, session: session)
    }
    /// Called after actual exact entry content download. A matching book policy
    /// alone is insufficient: the desired per-entry renderKey/hash must match.
    package func validate(_ content: ChatterboxBookEntryContent, session: ChapterAccountSession) throws {
        guard metadata.scope.accountPartition == session.accountPartition, book.supportsCurrentPlanner,
              metadata.intent.wanted, content.scopeID == metadata.scope.identifier,
              let entry = metadata.entries.first(where: { $0.chapterIndex == content.chapterIndex }),
              entry.content == (try content.identity()) else { throw ChapterBookJournalError.staleAdmission }
        switch content.entry {
        case .chapter(let pair):
            guard pair.submission.session == session, try pair.submission.request.renderKey() == entry.renderKey,
                  pair.submission.request.source.textSHA256 == entry.textSHA256,
                  pair.submission.request.source.utf16Length == entry.utf16Length else { throw ChapterWorkerError.invalidIdentity }
            try book.validate(pair, chapterIndex: content.chapterIndex)
        case .silent(let proof):
            guard entry.kind == .silent, entry.renderKey == nil, proof.textSHA256 == entry.textSHA256,
                  proof.utf16Length == entry.utf16Length else { throw ChapterWorkerError.invalidIdentity }
            try proof.validate(text: content.originalText)
        }
    }
}
