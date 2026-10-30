#if os(macOS)
import Foundation
import Synchronization
import LibroxChapterWorker
import LibroxChatterboxPlanning
import ChatterboxMacAcousticAudit

private final class LocalWorkerCancellation: Sendable {
    private struct Value: Sendable {
        var blocked = true, terminal = false
        var revision: UInt64 = 0
        var token: UUID?
        var cancel: (@Sendable () -> Void)?
    }
    private let value = Mutex(Value())
    var revision: UInt64 { value.withLock { $0.revision } }
    var accepting: Bool { value.withLock { !$0.blocked && !$0.terminal } }
    func allow(_ revision: UInt64) throws {
        try value.withLock {
            guard !$0.terminal else { throw ChatterboxMacWorkerError.closed }
            guard $0.revision == revision else { throw CancellationError() }
            $0.blocked = false
        }
    }
    func stop(terminal: Bool = false) {
        let callback = value.withLock { v -> (@Sendable () -> Void)? in
            v.blocked = true; v.terminal = v.terminal || terminal; if v.revision == .max { v.terminal = true } else { v.revision += 1 }; return v.cancel
        }
        callback?()
    }
    func register(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        let cancel = value.withLock { v in
            v.token = token; v.cancel = callback; return v.blocked || v.terminal
        }
        if cancel { callback() }; return token
    }
    func clear(_ token: UUID) { value.withLock { if $0.token == token { $0.token = nil; $0.cancel = nil } } }
}

public struct ChatterboxMacWorkerPublication: Sendable {
    public let readSet: ChapterIntentReadSet
    public let reference: ChapterLocalHandoffReference
    public let decodedFrames: Int64
    public let reusedCompletedAudio: Bool
    /// Worker-side admission/render/codec/custody/publication/join. Reader copy,
    /// playback startup and cloud are excluded. No timing claim until measured.
    public let completeWallSeconds, modelLoadingSeconds, completeWarmSeconds: Double
}

struct LocalWorkerLifecycleHooks: Sendable {
    var beforeStop: (@Sendable () async -> Void)? = nil
    var beforeEnableCommit: (@Sendable () async -> Void)? = nil
    var afterEnableClaims: (@Sendable () async -> Void)? = nil
    var beforeStorageSettlement: (@Sendable () async throws -> Void)? = nil
}

/// Owns one entire local production task chain. Construction does not load models;
/// explicit enabled work is required. Provider/catalog/runtime authority is external.
public actor ChatterboxMacLocalWorker {
    public enum Phase: Sendable, Equatable { case disabled, waiting, admitting, loading, rendering, adopting, publishing, joining, failed, closed }
    public enum Recovery: Sendable { case verifyCompleted, renderFresh }
    private struct OwnedResult: Sendable {
        let reference: ChapterLocalHandoffReference
        let frames: Int64
        let reused: Bool
        let loadingSeconds: Double
    }
    private let renderer: ChatterboxMacResidentRenderer
    private let journal: ChapterWorkerJournal
    private let directories: ChatterboxMacWorkerDirectories
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let nativeModelIdentity: String?
    private let artifactBudget: ChapterArtifactStorageBudget?
    private var storageAllowance: ChapterStorageReservation?
    private nonisolated let cancellation = LocalWorkerCancellation()
    private var enabled = false, stopping = false, closed = false, enabling = false
    private var stopCount = 0, terminalRequested = false
    private let hooks: LocalWorkerLifecycleHooks
    private var phase: Phase = .disabled
    private var operation: Task<OwnedResult, Error>?
    private var operationID: UUID?
    private var registration: UUID?
    private var joining: Task<Void, Error>?
    private var generation: ChapterWorkerGeneration?

    public init(assets: ChatterboxMacModelAssets, workerID: UUID, session: ChapterAccountSession,
                gate: ChapterAccountSessionGate, directories: ChatterboxMacWorkerDirectories,
                artifactBudget: ChapterArtifactStorageBudget) throws {
        try directories.validate()
        nativeModelIdentity = try StandardModelIdentity.modelSHA256()
        renderer = ChatterboxMacResidentRenderer(assets: assets)
        journal = try ChapterWorkerJournal(directory: directories.state, accountPartition: session.accountPartition, workerID: workerID)
        self.session = session; self.gate = gate; self.directories = directories; hooks = .init()
        self.artifactBudget = artifactBudget
    }
    init(renderer: ChatterboxMacResidentRenderer, journal: ChapterWorkerJournal, session: ChapterAccountSession,
         gate: ChapterAccountSessionGate, directories: ChatterboxMacWorkerDirectories, hooks: LocalWorkerLifecycleHooks = .init(),
         artifactBudget: ChapterArtifactStorageBudget? = nil) {
        nativeModelIdentity = nil // Internal synthetic seam, never a production profile.
        self.renderer = renderer; self.journal = journal; self.session = session; self.gate = gate; self.directories = directories; self.hooks = hooks
        self.artifactBudget = artifactBudget
    }
    public func state() -> Phase { phase }
    public func checkpoint(for request: ChapterRenderRequest) async throws -> ChapterWorkerCheckpoint? {
        try await gate.validate(session); try Task.checkCancellation()
        let result = try await journal.checkpoint(for: request)
        try await gate.validate(session); try Task.checkCancellation()
        return result
    }
    public func enable() async throws {
        guard !closed, !terminalRequested else { throw ChatterboxMacWorkerError.closed }
        guard !stopping, !enabling, operation == nil, storageAllowance == nil else { throw ChatterboxMacWorkerError.busy }
        enabling = true; defer { enabling = false }
        let stamp = cancellation.revision
        try directories.validate(); try await gate.validate(session); try Task.checkCancellation()
        if let artifactBudget {
            try await artifactBudget.requireExactManagedDirectories([directories.exports, directories.custody, directories.publications])
        }
        await hooks.beforeEnableCommit?()
        try Task.checkCancellation()
        guard !closed, !terminalRequested, !stopping, operation == nil, cancellation.revision == stamp else { throw CancellationError() }
        try await journal.setClaimsEnabled(true)
        do {
            await hooks.afterEnableClaims?()
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            guard !closed, !terminalRequested, !stopping, operation == nil else { throw CancellationError() }
            try cancellation.allow(stamp)
        } catch {
            enabled = false; cancellation.stop()
            try? await journal.setClaimsEnabled(false)
            if !closed { phase = stopping ? .joining : .disabled }
            throw error
        }
        enabled = true; phase = .waiting
    }
    public func render(_ readSet: ChapterIntentReadSet, authority: any ChapterIntentAuthority,
                       recovery: Recovery = .verifyCompleted) async throws -> ChatterboxMacWorkerPublication {
        guard !closed else { throw ChatterboxMacWorkerError.closed }
        guard enabled, cancellation.accepting else { throw ChatterboxMacWorkerError.disabled }
        guard !stopping, !enabling, operation == nil else { throw ChatterboxMacWorkerError.busy }
        let started = ContinuousClock.now, id = UUID(), stamp = cancellation.revision
        operationID = id; currentReadSet = readSet; phase = .admitting
        let task = Task { try await self.runOwned(readSet, authority: authority, recovery: recovery) }
        operation = task; registration = cancellation.register { task.cancel() }
        let outcome = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        // The separate cleanup task joins this exact producer task before any
        // journal relinquishment. Disable and caller continuations share it.
        try await joinOperation(id: id, readSet: readSet)
        let result = try outcome.get()
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
        guard enabled, cancellation.accepting, cancellation.revision == stamp, !closed else { throw CancellationError() }
        let seconds = started.duration(to: .now).seconds
        return .init(readSet: readSet, reference: result.reference, decodedFrames: result.frames, reusedCompletedAudio: result.reused,
            completeWallSeconds: seconds, modelLoadingSeconds: result.loadingSeconds, completeWarmSeconds: max(0, seconds - result.loadingSeconds))
    }
    private func runOwned(_ readSet: ChapterIntentReadSet, authority: any ChapterIntentAuthority, recovery: Recovery) async throws -> OwnedResult {
        try Task.checkCancellation(); try directories.validate()
        if let nativeModelIdentity {
            guard readSet.intent.request.recipe.stockVoiceID == "librox-narrator",
                  readSet.intent.request.recipe.conditioningSHA256 == ChatterboxMacAcousticSynthesizer.stockSHA256,
                  readSet.intent.request.recipe.modelSHA256 == nativeModelIdentity else { throw ChapterWorkerError.invalidManifest }
        }
        let prior = try await journal.checkpoint(for: readSet.intent.request)
        let token = try await journal.claim(readSet, authority: authority, session: session, gate: gate)
        // Register immediately, even if cancellation raced the claim return.
        generation = token
        try Task.checkCancellation()
        let submission = try await ChapterLocalSource.receive(readSet.sourceReference, request: readSet.intent.request,
            session: session, gate: gate, directory: directories.sourcePublications)
        let plan = try await ChatterboxLocalRenderPlan.receive(readSet.renderPlanReference, submission: submission,
            gate: gate, directory: directories.planPublications)
        try directories.validate()
        _ = try await journal.validateBeforeWork(token, authority: authority, session: session, gate: gate)
        let artifact: ChapterLocalArtifact
        var loadingSeconds = 0.0, reused = false
        let candidate = prior?.completedHandoff ?? prior?.plannedHandoff ?? prior?.recoveryHandoff
        if let artifactBudget {
            let bytes: UInt64
            if recovery == .verifyCompleted, let candidate {
                let manifest = try await ChapterLocalHandoff.inspectManifest(candidate, submission: submission,
                    gate: gate, directory: directories.publications)
                bytes = try ChatterboxMacWorkerStoragePolicy.recoveryAdmissionBytes(manifest)
            } else { bytes = ChatterboxMacWorkerStoragePolicy.freshAdmissionBytes }
            storageAllowance = try await artifactBudget.reserve(bytes: bytes)
            // Capture immediately, even if cancellation raced the return.
            try Task.checkCancellation()
        }
        _ = try await journal.validateBeforeWork(token, authority: authority, session: session, gate: gate)
        if recovery == .verifyCompleted, let candidate {
            phase = .adopting
            // Corrupt/missing candidates fail. No silent rerender/fallback.
            artifact = try await ChapterLocalHandoff.receive(candidate, submission: submission, gate: gate,
                directory: directories.publications, storageDirectory: directories.custody)
            reused = true
        } else {
            phase = .loading
            let wasCold = await renderer.state() == .cold, began = ContinuousClock.now
            _ = try await renderer.prepare()
            if wasCold { loadingSeconds = began.duration(to: .now).seconds }
            try directories.validate()
            _ = try await journal.validateBeforeWork(token, authority: authority, session: session, gate: gate)
            let binding = try await renderer.bindChapter(plan: plan, submission: submission, gate: gate)
            phase = .rendering
            let journal = self.journal, gate = self.gate, session = self.session, dirs = directories
            let budget = artifactBudget, allowance = storageAllowance
            let output = try await renderer.renderChapter(binding, gate: gate, outputDirectory: directories.exports) {
                try dirs.validate()
                _ = try await journal.validateBeforeWork(token, authority: authority, session: session, gate: gate)
                if let budget, let allowance { _ = try await budget.observeWithinCapacity(allowance) }
                _ = try await journal.validateBeforeWork(token, authority: authority, session: session, gate: gate)
            }
            try directories.validate()
            try await journal.recordProgress(.init(completedUnits: output.receipt.units.count, totalUnits: output.receipt.units.count),
                token: token, authority: authority, session: session, gate: gate)
            phase = .adopting
            artifact = try await binding.adopt(output, gate: gate, storageDirectory: directories.custody)
        }
        try directories.validate()
        if let artifactBudget, let storageAllowance { _ = try await artifactBudget.observeWithinCapacity(storageAllowance) }
        let expected = try await journal.beginPublication(token, artifact: artifact, submission: submission, authority: authority, gate: gate)
        phase = .publishing
        _ = try await journal.validateBeforeWork(token, authority: authority, session: session, gate: gate)
        let publication = try await ChapterLocalHandoff.publishVerified(artifact, submission: submission, gate: gate, directory: directories.publications)
        guard publication.reference == expected else { throw ChapterWorkerError.invalidManifest }
        try directories.validate()
        _ = try await journal.recordPublished(publication, token: token, authority: authority, gate: gate)
        try Task.checkCancellation()
        return .init(reference: publication.reference, frames: artifact.decodedFrameCount, reused: reused, loadingSeconds: loadingSeconds)
    }
    private func joinOperation(id: UUID, readSet: ChapterIntentReadSet) async throws {
        guard operationID == id, let operation else { return }
        if let joining { try await joining.value; return }
        phase = .joining
        let task = Task {
            let outcome = await operation.result // All work and component-owned children have joined.
            try await self.releaseJoined(id: id, readSet: readSet, outcome: outcome)
        }
        joining = task
        try await task.value
    }
    private func releaseJoined(id: UUID, readSet: ChapterIntentReadSet, outcome: Result<OwnedResult, Error>) async throws {
        guard operationID == id else { return }
        var storageError: Error?
        if let artifactBudget, let storageAllowance {
            do {
                try await hooks.beforeStorageSettlement?()
                switch outcome {
                case .success: _ = try await artifactBudget.settleAfterJoining(storageAllowance)
                case .failure: try await artifactBudget.releaseAfterJoining(storageAllowance)
                }
                self.storageAllowance = nil
            } catch {
                storageError = error
                do { try await artifactBudget.releaseAfterJoining(storageAllowance); self.storageAllowance = nil }
                catch { /* Keep ambiguous allowance/locks; never reuse it. */ }
            }
        }
        do {
            if let generation {
                try await journal.relinquishAfterJoining(generation, failure: storageError == nil ? Self.failure(outcome) : .storage)
            } else {
                _ = try await journal.checkpoint(for: readSet.intent.request) // Detect poisoned unreturned claim.
            }
        } catch {
            try? await journal.closeAfterJoining(generation)
            generation = nil; enabled = false; closed = true; cancellation.stop(terminal: true)
            await renderer.shutdown()
            try? await artifactBudget?.close()
            clearOperation(id); phase = .failed
            throw error
        }
        generation = nil; clearOperation(id)
        if let storageError {
            enabled = false; cancellation.stop(); phase = .failed
            throw storageError
        }
        phase = enabled && cancellation.accepting ? .waiting : .disabled
    }
    private func clearOperation(_ id: UUID) {
        guard operationID == id else { return }
        if let registration { cancellation.clear(registration) }
        registration = nil; operation = nil; operationID = nil; joining = nil; currentReadSet = nil
    }
    /// Same-turn host lifecycle fence: no Task/actor hop before admission stops
    /// and the current producer receives cancellation. Follow with disable or
    /// shutdown and await its join barrier before disposing the connection.
    public nonisolated func stopClaims() { cancellation.stop() }
    public nonisolated func disable() async throws {
        stopClaims()
        try await stopOwned(terminal: false)
    }
    public nonisolated func shutdown() async throws {
        cancellation.stop(terminal: true)
        try await stopOwned(terminal: true)
    }
    private func stopOwned(terminal: Bool) async throws {
        if closed { return }
        stopCount += 1; stopping = true; terminalRequested = terminalRequested || terminal
        defer { stopCount -= 1; stopping = stopCount != 0 }
        enabled = false
        await hooks.beforeStop?()
        try? await journal.setClaimsEnabled(false)
        operation?.cancel()
        var joinError: Error?
        if let id = operationID, let readSet = currentReadSet {
            do { try await joinOperation(id: id, readSet: readSet) } catch { joinError = error }
        }
        if terminalRequested {
            await renderer.shutdown()
            try await journal.close()
            try await artifactBudget?.close()
            closed = true; phase = .closed
        } else if !closed { phase = .disabled }
        if let joinError { throw joinError }
    }
    private var currentReadSet: ChapterIntentReadSet?
    private static func failure(_ outcome: Result<OwnedResult, Error>) -> ChapterWorkerFailure? {
        guard case .failure(let error) = outcome else { return nil }
        if error is CancellationError || error as? ChapterLocalIntentError == .staleIntent || error as? ChapterWorkerError == .accountMismatch
            || error as? ChapterWorkerJournalError == .disabled || error as? ChatterboxMacWorkerError == .disabled { return nil }
        if error is ChapterLocalSourceError || error is ChatterboxChapterRenderPlanError || error is ChatterboxMacWorkerError { return .source }
        if error is ChapterStorageBudgetError { return .storage }
        return .renderer
    }
}
private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
#endif
