import Foundation

/// Reader-side complete copy/decode admission and actual wanted-intent
/// acceptance. Metadata or a Worker publication alone never becomes playable.
public enum ChapterReaderStorageAdmission {
    enum Event: Sendable { case beforeCopy, beforeSettlement, beforeAcceptance, afterAcceptance }
    typealias Checkpoint = @Sendable (Event) async throws -> Void
    public static func receiveAndAccept(_ reference: ChapterLocalHandoffReference, submission: ChapterSubmission,
                                        readSet: ChapterIntentReadSet, gate: ChapterAccountSessionGate,
                                        outbox: ChapterDemandOutbox, budget: ChapterArtifactStorageBudget,
                                        publicationDirectory: URL, storageDirectory: URL) async throws -> ChapterReaderArtifactAcceptance {
        try await receiveAndAccept(reference, submission: submission, readSet: readSet, gate: gate, outbox: outbox,
            budget: budget, publicationDirectory: publicationDirectory, storageDirectory: storageDirectory,
            checkpoint: { _ in })
    }
    static func receiveAndAccept(_ reference: ChapterLocalHandoffReference, submission: ChapterSubmission,
                                 readSet: ChapterIntentReadSet, gate: ChapterAccountSessionGate,
                                 outbox: ChapterDemandOutbox, budget: ChapterArtifactStorageBudget,
                                 publicationDirectory: URL, storageDirectory: URL,
                                 checkpoint: @escaping Checkpoint) async throws -> ChapterReaderArtifactAcceptance {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        guard readSet.intent.request == submission.request, outbox.accountPartition == submission.session.accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        _ = try await outbox.durableIntentDescriptor()
        guard try await outbox.validateCurrent(readSet) else { throw ChapterLocalIntentError.staleIntent }
        try await budget.requireManagedDirectory(storageDirectory)
        let manifest = try await ChapterLocalHandoff.inspectManifest(reference, submission: submission,
            gate: gate, directory: publicationDirectory)
        // receive() pins the same metadata digest and enforces this exact length
        // before and during its private copy. There is no unbounded network stage.
        let allowance = try await budget.reserve(bytes: UInt64(manifest.audioByteCount))
        let task = Task {
            try await checkpoint(.beforeCopy)
            try Task.checkCancellation()
            return try await ChapterLocalHandoff.receive(reference, submission: submission, gate: gate,
                directory: publicationDirectory, storageDirectory: storageDirectory)
        }
        let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        let artifact: ChapterLocalArtifact
        do {
            artifact = try outcome.get() // Copy/decode producer and every child have joined.
            try await checkpoint(.beforeSettlement)
            _ = try await budget.settleAfterJoining(allowance)
        } catch {
            try await budget.releaseAfterJoining(allowance)
            throw error
        }
        try await checkpoint(.beforeAcceptance)
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        guard try ChapterLocalHandoff.contentReference(for: artifact, submission: submission) == reference
        else { throw ChapterLocalHandoffError.invalidReference }
        let result = try await outbox.acceptVerifiedHandoff(artifact,
            submission: submission, readSet: readSet, gate: gate)
        try await checkpoint(.afterAcceptance)
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        guard try await outbox.validateCurrent(readSet) else { throw ChapterLocalIntentError.staleIntent }
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return result
    }
}
