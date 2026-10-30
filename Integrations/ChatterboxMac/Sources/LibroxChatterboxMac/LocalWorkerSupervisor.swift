#if os(macOS)
import Foundation
import LibroxChapterWorker

/// Completion metadata only. The Reader still privately copies/decodes and
/// accepts audio against its own current intent before making it playable.
public struct ChatterboxMacLocalCompletionObservation: Sendable {
    public let receipt: ChapterLocalCompletionReceipt
    /// nil on an already-published observation. No cache/metadata lookup is
    /// reported as fresh inference speed; Worker timings exclude this wrapper.
    public let newPublication: ChatterboxMacWorkerPublication?
}

/// Owns the full local Worker + completion-metadata task chain. No polling,
/// cloud, catalog, app factory, or host inference authority is established here.
/// Call renderAndPublish only for an explicitly admitted current wanted intent.
public actor ChatterboxMacLocalWorkerSupervisor {
    private nonisolated let worker: ChatterboxMacLocalWorker
    private nonisolated let cancellation = LocalWorkerCancellation()
    private let budget: ChapterArtifactStorageBudget
    private let directory: URL
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let checkpoint: ChapterLocalCompletion.Checkpoint
    private let beforeAcceptance: @Sendable () async throws -> Void
    private var enabled = false, closed = false, terminalRequested = false
    private var stops = 0
    private var enabling: Task<Void, Error>?
    private var enablingID: UUID?
    private var operation: Task<ChatterboxMacLocalCompletionObservation, Error>?
    private var operationID: UUID?
    private var registration: UUID?
    private var acceptance: Task<Void, Error>?

    /// Transfers exclusive ownership of the Worker budget and all Worker tasks.
    /// No model load occurs until explicit enable + admitted rendering. The
    /// native runtime must be separately authorized by the signed host.
    public init(assets: ChatterboxMacModelAssets, workerID: UUID, session: ChapterAccountSession,
                gate: ChapterAccountSessionGate, directories: ChatterboxMacWorkerDirectories,
                artifactBudget: ChapterArtifactStorageBudget) throws {
        worker = try ChatterboxMacLocalWorker(assets: assets, workerID: workerID, session: session,
            gate: gate, directories: directories, artifactBudget: artifactBudget)
        budget = artifactBudget; directory = directories.publications
        self.session = session; self.gate = gate; checkpoint = { _ in }; beforeAcceptance = {}
    }
    // Synthetic tests transfer an existing owned Worker. Never an app factory.
    init(worker: ChatterboxMacLocalWorker, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
         budget: ChapterArtifactStorageBudget, directory: URL,
         beforeAcceptance: @escaping @Sendable () async throws -> Void = {},
         checkpoint: @escaping ChapterLocalCompletion.Checkpoint = { _ in }) {
        self.worker = worker; self.session = session; self.gate = gate
        self.budget = budget; self.directory = directory; self.checkpoint = checkpoint
        self.beforeAcceptance = beforeAcceptance
    }
    deinit { cancellation.stop(terminal: true); worker.stopClaims() }
    func acceptingClaims() async -> Bool {
        let accepted = await worker.acceptingClaims()
        return accepted && enabled && cancellation.accepting && !closed && !terminalRequested && stops == 0
    }

    public func enable() async throws {
        guard !closed, !terminalRequested else { throw ChatterboxMacWorkerError.closed }
        guard stops == 0, enabling == nil, operation == nil else { throw ChatterboxMacWorkerError.busy }
        let id = UUID(), stamp = cancellation.revision
        let worker = self.worker, gate = self.gate, session = self.session
        let task = Task {
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            try await worker.enable()
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        }
        enablingID = id; enabling = task
        let token = cancellation.register(enablingAtRevision: stamp) { task.cancel() }
        defer {
            cancellation.clear(token)
            if enablingID == id { enabling = nil; enablingID = nil }
        }
        let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        do {
            try outcome.get(); try Task.checkCancellation()
            try await gate.validate(session); try Task.checkCancellation()
            guard stops == 0, !closed, !terminalRequested else { throw CancellationError() }
            try cancellation.allow(stamp); enabled = true
        } catch {
            enabled = false; worker.stopClaims()
            try? await worker.disable()
            throw error
        }
    }

    public func renderAndPublish(_ readSet: ChapterIntentReadSet, authority: any ChapterIntentAuthority) async throws
        -> ChatterboxMacLocalCompletionObservation {
        guard !closed, !terminalRequested else { throw ChatterboxMacWorkerError.closed }
        guard enabled, cancellation.accepting else { throw ChatterboxMacWorkerError.disabled }
        guard stops == 0, enabling == nil, operation == nil else { throw ChatterboxMacWorkerError.busy }
        let id = UUID(), stamp = cancellation.revision
        let worker = self.worker, session = self.session, gate = self.gate, budget = self.budget
        let directory = self.directory, checkpoint = self.checkpoint, fence = cancellation
        let task = Task { () throws -> ChatterboxMacLocalCompletionObservation in
            try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
            let result: ChatterboxMacLocalCompletionObservation
            if let receipt = try await ChapterLocalCompletion.receiveIfPresent(for: readSet, session: session,
                gate: gate, authority: authority, directory: directory) {
                // Metadata discovery never verifies/resumes audio. Require the
                // private Worker evidence too; corruption must not trigger a
                // silent fresh render. Reader admission still verifies audio.
                guard let prior = try await worker.checkpoint(for: readSet.intent.request), prior.readSet == readSet,
                      prior.completedHandoff == receipt.handoffReference else { throw ChapterLocalCompletionError.invalidRecord }
                try Task.checkCancellation()
                guard fence.accepting, fence.revision == stamp else { throw CancellationError() }
                result = .init(receipt: receipt, newPublication: nil)
            } else {
                let publication = try await worker.render(readSet, authority: authority)
                let receipt = try await ChatterboxMacLocalCompletionPublisher.publish(publication, gate: gate,
                    authority: authority, budget: budget, directory: directory, checkpoint: checkpoint)
                result = .init(receipt: receipt, newPublication: publication)
            }
            try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
            try Task.checkCancellation()
            guard fence.accepting, fence.revision == stamp else { throw CancellationError() }
            return result
        }
        operationID = id; operation = task; registration = cancellation.register { task.cancel() }
        defer { clearOperation(id) }
        let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        let result = try outcome.get()
        try Task.checkCancellation()
        guard enabled, stops == 0, cancellation.accepting, cancellation.revision == stamp, !closed else { throw CancellationError() }
        // Post-producer acceptance is a separate OWNED stage. Keep the public
        // operation slot until it joins; stops must also join its authority IO.
        let beforeAcceptance = self.beforeAcceptance
        let finalCheck = Task {
            try await beforeAcceptance()
            try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
        }
        acceptance = finalCheck
        if let registration { cancellation.clear(registration) }
        registration = cancellation.register { finalCheck.cancel() }
        try await withTaskCancellationHandler { try await finalCheck.value } onCancel: { finalCheck.cancel() }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard enabled, stops == 0, cancellation.accepting, cancellation.revision == stamp, !closed else { throw CancellationError() }
        return result
    }

    /// Same host-event turn: block admission and signal BOTH the complete
    /// supervisor producer and underlying Worker. Then await disable/shutdown.
    public nonisolated func stopClaims() { cancellation.stop(); worker.stopClaims() }
    public nonisolated func disable() async throws {
        stopClaims(); try await stopOwned(terminal: false)
    }
    public nonisolated func shutdown() async throws {
        cancellation.stop(terminal: true); worker.stopClaims()
        try await stopOwned(terminal: true)
    }
    private func stopOwned(terminal: Bool) async throws {
        if closed { return }
        stops += 1; terminalRequested = terminalRequested || terminal; enabled = false
        defer { stops -= 1 }
        if let enabling { enabling.cancel(); _ = await enabling.result }
        if let operation { operation.cancel(); _ = await operation.result }
        if let acceptance { acceptance.cancel(); _ = await acceptance.result }
        // Every receipt/file producer is now joined. Worker alone owns its
        // journal release/model/budget shutdown; never release those twice.
        if terminalRequested {
            try await worker.shutdown(); closed = true
        } else { try await worker.disable() }
    }
    private func clearOperation(_ id: UUID) {
        guard operationID == id else { return }
        if let registration { cancellation.clear(registration) }
        registration = nil; operation = nil; operationID = nil; acceptance = nil
    }
}
#endif
