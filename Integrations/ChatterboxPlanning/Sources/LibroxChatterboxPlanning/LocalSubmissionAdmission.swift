import Foundation
import LibroxChapterWorker

/// Reader-only exact immutable source/options admission. No renderer or cloud
/// work. The Reader's control journal is intentionally outside these write caps.
public enum ChatterboxLocalSubmissionAdmission {
    /// Each bounded blob may temporarily have its staged and published path.
    /// Count both logical paths conservatively even though they share an inode.
    public static let maximumPublicationGrowthBytes = UInt64(2 * (ChapterLocalSource.maximumPayloadBytes + ChatterboxLocalRenderPlan.maximumPayloadBytes))
    enum Event: Sendable { case afterSource, beforeSettlement, beforeIntent, afterIntent }
    typealias Checkpoint = @Sendable (Event) async throws -> Void

    public static func submit(_ plan: ChatterboxChapterRenderPlan, submission: ChapterSubmission,
                              gate: ChapterAccountSessionGate, outbox: ChapterDemandOutbox,
                              budget: ChapterArtifactStorageBudget, sourceDirectory: URL,
                              planDirectory: URL) async throws -> ChapterDemandIntent {
        try await submit(plan, submission: submission, gate: gate, outbox: outbox, budget: budget,
                         sourceDirectory: sourceDirectory, planDirectory: planDirectory, checkpoint: { _ in })
    }
    static func submit(_ plan: ChatterboxChapterRenderPlan, submission: ChapterSubmission,
                       gate: ChapterAccountSessionGate, outbox: ChapterDemandOutbox,
                       budget: ChapterArtifactStorageBudget, sourceDirectory: URL, planDirectory: URL,
                       checkpoint: @escaping Checkpoint) async throws -> ChapterDemandIntent {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        guard await outbox.accountPartition == submission.session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        _ = try await outbox.durableIntentDescriptor() // Plain or closed writers cannot admit offline work.
        try ChatterboxLocalRenderPlan.validate(plan, submission: submission)
        let admission = try await outbox.observeAdmission(for: submission.request)
        try await budget.requireManagedDirectory(sourceDirectory)
        try await budget.requireManagedDirectory(planDirectory)
        let allowance = try await budget.reserve(bytes: maximumPublicationGrowthBytes)
        let task = Task {
            try Task.checkCancellation()
            let source = try await ChapterLocalSource.publish(submission, gate: gate, directory: sourceDirectory)
            try await checkpoint(.afterSource)
            try Task.checkCancellation()
            let options = try await ChatterboxLocalRenderPlan.publish(plan, submission: submission,
                source: source, gate: gate, directory: planDirectory)
            return (source, options)
        }
        let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        let publications: (ChapterLocalSourcePublication, ChapterLocalRenderPlanPublication)
        do {
            publications = try outcome.get() // Exact source/options producers and their children joined.
            try await checkpoint(.beforeSettlement)
            _ = try await budget.settleAfterJoining(allowance)
        } catch {
            try await budget.releaseAfterJoining(allowance)
            throw error
        }
        // No intent is made wanted until all bounded writes settled. A failure
        // may retain immutable blobs, which alone never authorize any work.
        try await checkpoint(.beforeIntent)
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        let result = try await outbox.setDemand(true, for: submission.request,
            source: publications.0, renderPlan: publications.1, admission: admission)
        try await checkpoint(.afterIntent)
        // A cancellation here is a lost acknowledgement, not a rollback. The
        // authoritative journal remains recoverable and cancellation stays usable.
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return result
    }
}
