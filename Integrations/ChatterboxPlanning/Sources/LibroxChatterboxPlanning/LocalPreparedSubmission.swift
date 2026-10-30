import Foundation
import LibroxChapterWorker

/// SDK recovery for the prepared service's durable exact pair. Read-only:
/// restores neither wanted demand nor a model/voice/playback permission.
public enum ChatterboxLocalPreparedSubmission {
    enum Event: Sendable { case afterSource, afterPlan }
    typealias Checkpoint = @Sendable (Event) async throws -> Void

    /// nil means no stored complete source/options pair. Missing/corrupt files,
    /// unavailable Reader authority or changed journal/session throw. Cancelled
    /// entries may retain options for explicit UI recovery, never implicit work.
    public static func recover(for request: ChapterRenderRequest, session: ChapterAccountSession,
                               gate: ChapterAccountSessionGate, outbox: ChapterDemandOutbox,
                               sourceDirectory: URL, planDirectory: URL) async throws -> ChatterboxPreparedChapterSubmission? {
        try await recover(for: request, session: session, gate: gate, outbox: outbox,
            sourceDirectory: sourceDirectory, planDirectory: planDirectory, checkpoint: { _ in })
    }
    static func recover(for request: ChapterRenderRequest, session: ChapterAccountSession,
                        gate: ChapterAccountSessionGate, outbox: ChapterDemandOutbox,
                        sourceDirectory: URL, planDirectory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChatterboxPreparedChapterSubmission? {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        try request.validate()
        guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let descriptor = try await outbox.durableIntentDescriptor() // Explicit Reader role, never a Worker journal.
        guard descriptor.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let stored = try await outbox.storedSubmission(for: request)
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard let stored, let planReference = stored.renderPlanReference else { return nil }
        guard try stored.intent.request.renderKey() == request.renderKey() else { throw ChapterWorkerError.invalidIdentity }
        let task = Task {
            let submission = try await ChapterLocalSource.receive(stored.sourceReference, request: request,
                session: session, gate: gate, directory: sourceDirectory)
            try await checkpoint(.afterSource)
            try Task.checkCancellation()
            let plan = try await ChatterboxLocalRenderPlan.receive(planReference, submission: submission,
                gate: gate, directory: planDirectory)
            try await checkpoint(.afterPlan)
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            return ChatterboxPreparedChapterSubmission(submission: submission, plan: plan)
        }
        let recovered = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        // Exact owned source/options reads and their children have joined. This
        // actor observation never updates intent, acknowledgement or references.
        guard try await outbox.storedSubmission(for: request) == stored else { throw ChapterLocalIntentError.staleIntent }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        return recovered
    }
}
