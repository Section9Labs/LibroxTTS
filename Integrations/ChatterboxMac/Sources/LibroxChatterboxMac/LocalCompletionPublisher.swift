#if os(macOS)
import Foundation
import LibroxChapterWorker

/// The forthcoming SDK service supervisor owns this task AFTER render returns,
/// cancels/joins it BEFORE worker shutdown, and never exposes it as app glue.
/// A live publication can only be created after the owned render chain joins.
package enum ChatterboxMacLocalCompletionPublisher {
    package static func publish(_ publication: ChatterboxMacWorkerPublication,
                                gate: ChapterAccountSessionGate, authority: any ChapterIntentAuthority,
                                budget: ChapterArtifactStorageBudget, directory: URL,
                                checkpoint: @escaping ChapterLocalCompletion.Checkpoint = { _ in }) async throws -> ChapterLocalCompletionReceipt {
        try publication.producerFence()
        try await gate.validate(publication.producerSession); try Task.checkCancellation()
        try await budget.requireManagedDirectory(directory)
        let allowance = try await budget.reserve(bytes: UInt64(ChapterLocalCompletion.maximumPayloadBytes * 2))
        let task = Task {
            try publication.producerFence()
            return try await ChapterLocalCompletion.publish(readSet: publication.readSet, handoffReference: publication.reference,
                session: publication.producerSession, gate: gate, authority: authority, directory: directory,
                producerFence: publication.producerFence, checkpoint: checkpoint)
        }
        let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        let result: ChapterLocalCompletionReceipt
        do {
            result = try outcome.get() // Exact metadata producer and all file children joined.
            _ = try await budget.settleAfterJoining(allowance)
        } catch {
            try await budget.releaseAfterJoining(allowance)
            throw error
        }
        try publication.producerFence()
        try Task.checkCancellation(); try await gate.validate(publication.producerSession); try Task.checkCancellation()
        try await ChapterLocalIntentSnapshot.requireCurrent(publication.readSet, authority: authority,
            session: publication.producerSession, gate: gate)
        try publication.producerFence()
        return result
    }
}
#endif
