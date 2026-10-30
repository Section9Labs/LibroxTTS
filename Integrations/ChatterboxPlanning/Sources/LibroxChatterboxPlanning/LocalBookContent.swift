import Foundation
import LibroxChapterWorker

/// Reader-owned durable source/options upload material. Not current book/cloud
/// authority. Workers never open this Reader mutable outbox or inherit its epoch.
package enum ChatterboxLocalBookContent {
    package static let maximumPublicationGrowthBytes: UInt64 = 16 * 1024 * 1024
    enum Event: Sendable { case beforePublish, afterPublish, beforeSettlement, beforeIntent, afterIntent }
    typealias Checkpoint = @Sendable (Event) async throws -> Void

    package static func persist(_ content: ChatterboxBookEntryContent, book: ChatterboxPreparedBookSubmission,
                                session: ChapterAccountSession, gate: ChapterAccountSessionGate, outbox: ChapterBookOutbox,
                                budget: ChapterArtifactStorageBudget, directory: URL, sourceDirectory: URL, planDirectory: URL) async throws -> ChapterBookDemandIntent {
        try await persist(content, book: book, session: session, gate: gate, outbox: outbox, budget: budget,
            directory: directory, sourceDirectory: sourceDirectory, planDirectory: planDirectory, checkpoint: { _ in })
    }
    static func persist(_ content: ChatterboxBookEntryContent, book: ChatterboxPreparedBookSubmission,
                        session: ChapterAccountSession, gate: ChapterAccountSessionGate, outbox: ChapterBookOutbox,
                        budget: ChapterArtifactStorageBudget, directory: URL, sourceDirectory: URL, planDirectory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChapterBookDemandIntent {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        let identity = try content.identity()
        let outboxPartition = await outbox.accountPartition
        try await gate.validate(session); try Task.checkCancellation()
        guard identity.accountPartition == session.accountPartition, identity.scopeID == book.scope.identifier,
              outboxPartition == session.accountPartition else {
            throw ChapterWorkerError.accountMismatch
        }
        // Format activation is a control write independent of artifact capacity.
        try await outbox.activateContentQueue()
        try await gate.validate(session); try Task.checkCancellation()
        let admission = try await outbox.observeAdmission(scopeID: book.scope.identifier, chapterIndex: content.chapterIndex)
        try await budget.requireManagedDirectory(directory)
        let allowance = try await budget.reserve(bytes: maximumPublicationGrowthBytes)
        let producer = Task {
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            let bytes = try content.encoded()
            // Pure roundtrip also validates the exact supplied book/settings and
            // source, rather than trusting a blob's opaque self-consistent hash.
            _ = try ChatterboxBookEntryContent.decode(bytes, identity: identity, book: book,
                chapterIndex: content.chapterIndex, session: session)
            if case .chapter(let prepared) = content.entry {
                guard prepared.submission.session == session, let prior = admission.prior,
                      let request = prior.request, let sourceRef = prior.sourceReference, let planRef = prior.renderPlanReference,
                      try request.renderKey() == prepared.submission.request.renderKey() else { throw ChapterBookJournalError.staleAdmission }
                // Read the REAL previously admitted immutable pair. An app-made
                // request or copied plan hash cannot invent a durable local pair.
                let source = try await ChapterLocalSource.receive(sourceRef, request: request, session: session,
                    gate: gate, directory: sourceDirectory)
                let plan = try await ChatterboxLocalRenderPlan.receive(planRef, submission: source, gate: gate, directory: planDirectory)
                guard Data(source.originalText.utf8) == Data(content.originalText.utf8), plan.encoded() == prepared.plan.encoded() else {
                    throw ChatterboxChapterRenderPlanError.sourceMismatch
                }
            }
            try await checkpoint(.beforePublish)
            try await ChapterImmutableBlob.publish(bytes, identifier: identity.payloadSHA256, directory: directory,
                maximumBytes: ChatterboxBookEntryContent.maximumBytes) {
                    try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
                }
            try await checkpoint(.afterPublish)
            try await gate.validate(session); try Task.checkCancellation()
        }
        let result = await withTaskCancellationHandler { await producer.result } onCancel: { producer.cancel() }
        do {
            try result.get(); try await checkpoint(.beforeSettlement)
            _ = try await budget.settleAfterJoining(allowance)
        } catch { try await budget.releaseAfterJoining(allowance); throw error }
        try await checkpoint(.beforeIntent)
        try await gate.validate(session); try Task.checkCancellation()
        let request: ChapterRenderRequest?, silent: ChapterBookSilentSource?
        switch content.entry {
        case .chapter(let prepared): request = prepared.submission.request; silent = nil
        case .silent(let proof): request = nil; silent = proof
        }
        let intent = try await outbox.attachContent(identity, request: request, silent: silent,
            originalText: content.originalText, admission: admission)
        try await checkpoint(.afterIntent)
        try await gate.validate(session); try Task.checkCancellation(); return intent
    }

    /// Reads actual bounded bytes, with exact hash/canonical/source/options
    /// checks under the caller's OWN current epoch. It grants no upload/work.
    package static func receive(_ identity: ChapterBookEntryContentIdentity, book: ChatterboxPreparedBookSubmission,
                                session: ChapterAccountSession, gate: ChapterAccountSessionGate, directory: URL) async throws -> ChatterboxBookEntryContent {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard identity.accountPartition == session.accountPartition, identity.scopeID == book.scope.identifier else {
            throw ChapterWorkerError.accountMismatch
        }
        let producer = Task.detached(priority: .utility) {
            let bytes = try ChapterImmutableBlob.read(identity.payloadSHA256, directory: directory,
                maximumBytes: ChatterboxBookEntryContent.maximumBytes)
            let content = try ChatterboxBookEntryContent.decode(bytes, identity: identity, book: book,
                chapterIndex: identity.chapterIndex, session: session)
            try await gate.validate(session); try Task.checkCancellation(); return content
        }
        let value = try await withTaskCancellationHandler { try await producer.value } onCancel: { producer.cancel() }
        try await gate.validate(session); try Task.checkCancellation(); return value
    }
}
