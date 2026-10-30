import Foundation
import LibroxChapterWorker

/// One finite Reader-owned pending-content transfer. No background task escapes
/// this awaited call. The eventual service owns/cancels/joins its calling Task.
/// This does NOT publish book intent, grant work or activate a factory.
package enum ChatterboxBookContentUpload {
    /// Upload capture plus finite reconciliation capture and metadata headroom.
    /// Soft retained logical-byte admission, not wire/OS/native transient quota.
    package static let maximumTransferGrowthBytes: UInt64 = 24 * 1024 * 1024
    enum Event: Sendable { case afterRead, afterServerReceipt, beforeSettlement, beforeConfirmation, afterConfirmation }
    typealias Checkpoint = @Sendable (Event) async throws -> Void
    package static func reconcileOne(book: ChatterboxPreparedBookSubmission, session: ChapterAccountSession,
                                     gate: ChapterAccountSessionGate, outbox: ChapterBookOutbox, directory: URL,
                                     budget: ChapterArtifactStorageBudget, transport: ChapterCloudBookEntryTransport) async throws -> ChapterBookContentServerReceipt? {
        try await reconcileOne(book: book, session: session, gate: gate, outbox: outbox, directory: directory,
            budget: budget, transport: transport, checkpoint: { _ in })
    }
    static func reconcileOne(book: ChatterboxPreparedBookSubmission, session: ChapterAccountSession,
                             gate: ChapterAccountSessionGate, outbox: ChapterBookOutbox, directory: URL,
                             budget: ChapterArtifactStorageBudget, transport: ChapterCloudBookEntryTransport,
                             checkpoint: @escaping Checkpoint) async throws -> ChapterBookContentServerReceipt? {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        let partition = await outbox.accountPartition, transportSession = await transport.boundSession
        try await gate.validate(session); try Task.checkCancellation()
        guard partition == session.accountPartition, book.scope.accountPartition == session.accountPartition,
              transportSession == session else { throw ChapterWorkerError.accountMismatch }
        guard let observation = try await outbox.observePendingContentUpload(scopeID: book.scope.identifier) else {
            try await gate.validate(session); try Task.checkCancellation(); return nil
        }
        guard observation.scope == book.scope, let identity = observation.chapter.contentIdentity else {
            throw ChapterBookJournalError.staleAdmission
        }
        let captureDirectory = await transport.captureDirectory
        try await gate.validate(session); try Task.checkCancellation()
        try await budget.requireManagedDirectory(directory); try await budget.requireManagedDirectory(captureDirectory)
        let allowance = try await budget.reserve(bytes: maximumTransferGrowthBytes)
        let producer = Task {
            let content = try await ChatterboxLocalBookContent.receive(identity, book: book, session: session, gate: gate, directory: directory)
            // Compare against the actual admitted entry, not only the book's
            // common policy: authored controls may change within that policy.
            switch content.entry {
            case .chapter(let pair):
                guard let expected = observation.chapter.request,
                      try expected.renderKey() == pair.submission.request.renderKey() else { throw ChapterBookJournalError.staleAdmission }
            case .silent(let proof):
                guard observation.chapter.request == nil, observation.chapter.silentTextSHA256 == proof.textSHA256,
                      observation.chapter.silentUTF16Length == proof.utf16Length else { throw ChapterBookJournalError.staleAdmission }
            }
            try await checkpoint(.afterRead)
            try await gate.validate(session); try Task.checkCancellation()
            guard try await outbox.pendingContentUploadIsCurrent(observation) else { throw ChapterBookJournalError.staleAdmission }
            let receipt = try await transport.upload(content.encoded(), identity: identity)
            try await checkpoint(.afterServerReceipt)
            try await gate.validate(session); try Task.checkCancellation()
            guard receipt.session == session, receipt.identity == identity else { throw ChapterWorkerError.accountMismatch }
            return receipt
        }
        let result = await withTaskCancellationHandler { await producer.result } onCancel: { producer.cancel() }
        let receipt: ChapterBookContentServerReceipt
        do {
            receipt = try result.get(); try await checkpoint(.beforeSettlement)
            _ = try await budget.settleAfterJoining(allowance)
        } catch { try await budget.releaseAfterJoining(allowance); throw error }
        try await checkpoint(.beforeConfirmation)
        try await gate.validate(session); try Task.checkCancellation()
        guard try await outbox.confirmContent(identity, intent: observation.intent, serverRevision: receipt.revision) else {
            throw ChapterBookJournalError.staleAdmission
        }
        try await checkpoint(.afterConfirmation)
        try await gate.validate(session); try Task.checkCancellation(); return receipt
    }
}
