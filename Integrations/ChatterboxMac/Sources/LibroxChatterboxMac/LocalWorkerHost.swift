#if os(macOS)
import Foundation
import LibroxChapterWorker
import LibroxChatterboxPlanning
import ChatterboxMacAcousticAudit

/// Native stock-model host and real bounded current-intent queue driver.
/// Construction is cold. Only explicit start prepares the model and enables
/// claims. Host/account/runtime authorization remains the application's gate.
public actor ChatterboxMacLocalWorkerHost {
    public enum State: Sendable { case disabled, preparing, prepared, running, waitingForReader, closed }
    public struct Snapshot: Sendable {
        public let state: State
        public let workerPhase: ChatterboxMacLocalWorker.Phase
        public let activeRequest: ChapterRenderRequest?
        public let wantedCount: Int
        public let lastFailure: ChapterServiceFailure?
    }
    private let renderer: ChatterboxMacResidentRenderer
    private nonisolated let supervisor: ChatterboxMacLocalWorkerSupervisor
    private let worker: ChatterboxMacLocalWorker
    private let authority: ChapterDurableIntentAuthority
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let modelIdentity: String?
    private let approval: ChapterStockCapability.ListeningApproval
    private nonisolated let cancellation = LocalWorkerCancellation()
    private var descriptor: ChatterboxStockVoiceDescriptor?
    private var startTask: Task<ChatterboxStockVoiceDescriptor, Error>?
    private var runner: Task<Void, Never>?
    private var registration: UUID?
    private var state: State = .disabled
    private var activeRequest: ChapterRenderRequest?
    private var wantedCount = 0
    private var lastFailure: ChapterServiceFailure?
    private var stops = 0, terminal = false

    /// Owns Worker-only State/Exports/Custody/Publications. Reader source/plan
    /// and authority paths are read-only and must be authorized by the host.
    /// No model prediction or download occurs during this cold construction.
    public static func open(assets: ChatterboxMacModelAssets, workerID: UUID,
                            session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                            directories: ChatterboxMacWorkerDirectories, authority: ChapterDurableIntentAuthority,
                            storagePolicy: ChapterStorageBudgetPolicy,
                            listeningApproval: ChapterStockCapability.ListeningApproval = .pending) async throws -> ChatterboxMacLocalWorkerHost {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            try directories.validate()
            guard authority.descriptor.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
            let budget = try ChapterArtifactStorageBudget(controlDirectory: directories.exports,
                managedDirectories: [directories.exports, directories.custody, directories.publications], policy: storagePolicy)
            var journal: ChapterWorkerJournal?
            do {
                let model = try StandardModelIdentity.modelSHA256()
                let renderer = ChatterboxMacResidentRenderer(assets: assets)
                let owned = try ChapterWorkerJournal(directory: directories.state, accountPartition: session.accountPartition, workerID: workerID)
                journal = owned
                try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
                let worker = ChatterboxMacLocalWorker(renderer: renderer, journal: owned, session: session, gate: gate,
                    directories: directories, artifactBudget: budget, nativeModelIdentity: model)
                return ChatterboxMacLocalWorkerHost(renderer: renderer, worker: worker, budget: budget,
                    session: session, gate: gate, directories: directories, authority: authority,
                    modelIdentity: model, approval: listeningApproval)
            } catch {
                try? await journal?.close(); try? await budget.close(); throw error
            }
        }
        let host = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do { try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation(); return host }
        catch { try? await host.shutdown(); throw error }
    }
    init(renderer: ChatterboxMacResidentRenderer, worker: ChatterboxMacLocalWorker, budget: ChapterArtifactStorageBudget,
         session: ChapterAccountSession, gate: ChapterAccountSessionGate, directories: ChatterboxMacWorkerDirectories,
         authority: ChapterDurableIntentAuthority, modelIdentity: String? = nil,
         approval: ChapterStockCapability.ListeningApproval = .pending) {
        self.renderer = renderer; self.worker = worker; self.session = session; self.gate = gate; self.authority = authority
        self.modelIdentity = modelIdentity; self.approval = approval
        supervisor = .init(worker: worker, session: session, gate: gate, budget: budget, directory: directories.publications)
    }
    deinit { cancellation.stop(terminal: true); supervisor.stopClaims(); runner?.cancel(); startTask?.cancel() }

    public func start() async throws {
        guard !terminal else { throw ChatterboxMacWorkerError.closed }
        guard approval != .rejected else { throw ChatterboxLocalPreparedServiceError.notReady }
        guard stops == 0, startTask == nil, runner == nil else { throw ChatterboxMacWorkerError.busy }
        let stamp = cancellation.revision
        state = .preparing
        let renderer = self.renderer, supervisor = self.supervisor, session = self.session, gate = self.gate
        let authority = self.authority, modelIdentity = self.modelIdentity, approval = self.approval
        let task = Task {
            // An unavailable authority is not a genuine empty queue.
            _ = try await authority.wantedSnapshot(session: session, gate: gate)
            _ = try await renderer.prepare()
            let descriptor = try await renderer.stockVoiceDescriptor()
            if let modelIdentity {
                guard descriptor.modelSHA256 == modelIdentity,
                      descriptor.conditioningSHA256 == ChatterboxMacAcousticSynthesizer.stockSHA256
                else { throw ChapterWorkerError.invalidManifest }
            }
            try await gate.validate(session); try Task.checkCancellation()
            _ = try await authority.wantedSnapshot(session: session, gate: gate)
            // Preparing a pending voice is not permission to claim queued work.
            if approval == .approved { try await supervisor.enable() }
            return descriptor
        }
        startTask = task
        let token = cancellation.register(enablingAtRevision: stamp) { task.cancel() }
        defer { cancellation.clear(token); startTask = nil }
        do {
            let descriptor = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            guard stops == 0, !terminal else { throw CancellationError() }
            try cancellation.allow(stamp)
            self.descriptor = descriptor; state = .prepared; lastFailure = nil
            guard approval == .approved else { return }
            state = .running
            let driver = Task { [weak self] in
                await Self.drive(supervisor: supervisor, authority: authority, session: session, gate: gate) { [weak self] event in
                    await self?.record(event, revision: stamp)
                }
                await self?.driverEnded(revision: stamp)
            }
            runner = driver; registration = cancellation.register { driver.cancel() }
        } catch {
            supervisor.stopClaims(); try? await supervisor.disable()
            if !terminal { state = .disabled }
            throw error
        }
    }
    /// This in-process endpoint supplies metadata from the ACTUALLY prepared
    /// backend. It is not serialized IPC or CloudKit descriptor authentication.
    public func catalog(for readerSession: ChapterAccountSession, gate readerGate: ChapterAccountSessionGate) async throws -> ChatterboxStockCatalog {
        try Task.checkCancellation(); try await readerGate.validate(readerSession); try await gate.validate(session)
        guard readerSession.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard let descriptor, !terminal else { throw ChatterboxLocalPreparedServiceError.notReady }
        let acceptsClaims = await supervisor.acceptingClaims()
        try await readerGate.validate(readerSession); try await gate.validate(session); try Task.checkCancellation()
        guard !terminal else { throw ChatterboxMacWorkerError.closed }
        let available = acceptsClaims && cancellation.accepting && stops == 0 && runner != nil && state == .running
        return try ChatterboxStockCatalog(session: readerSession,
            voices: [.init(descriptor: descriptor, availability: available ? .available : .unavailable, listeningApproval: approval)], deliveryDomain: .local)
    }
    public func snapshot() async throws -> Snapshot {
        try await gate.validate(session); try Task.checkCancellation()
        let phase = await worker.state()
        try await gate.validate(session); try Task.checkCancellation()
        return .init(state: state, workerPhase: phase, activeRequest: activeRequest, wantedCount: wantedCount, lastFailure: lastFailure)
    }
    public nonisolated func stopClaims() { cancellation.stop(); supervisor.stopClaims() }
    public nonisolated func disable() async throws { stopClaims(); try await stopOwned(terminal: false) }
    public nonisolated func shutdown() async throws {
        cancellation.stop(terminal: true); supervisor.stopClaims(); try await stopOwned(terminal: true)
    }
    private func stopOwned(terminal: Bool) async throws {
        if state == .closed { return }
        stops += 1; self.terminal = self.terminal || terminal
        defer { stops -= 1 }
        if let startTask { startTask.cancel(); _ = await startTask.result }
        if let runner { runner.cancel(); await runner.value }
        runner = nil
        if let registration { cancellation.clear(registration) }; registration = nil
        activeRequest = nil; wantedCount = 0
        if self.terminal { try await supervisor.shutdown(); state = .closed }
        else { try await supervisor.disable(); state = .disabled }
    }
    private enum Event: Sendable {
        case snapshot(Int), rendering(ChapterRenderRequest), completed
        case failed(ChapterServiceFailure), unavailable
    }
    private func record(_ event: Event, revision: UInt64) {
        guard !terminal, stops == 0, cancellation.accepting, cancellation.revision == revision else { return }
        switch event {
        case .snapshot(let count): wantedCount = count; state = .running
        case .rendering(let request): activeRequest = request; lastFailure = nil
        case .completed: activeRequest = nil
        case .failed(let failure): lastFailure = failure; activeRequest = nil
        case .unavailable: state = .waitingForReader; activeRequest = nil
        }
    }
    private func driverEnded(revision: UInt64) {
        guard !terminal, cancellation.revision == revision else { return }
        cancellation.stop(); supervisor.stopClaims()
        state = .disabled; activeRequest = nil
        // Keep the exact completed runner handle until disable/shutdown joins it.
    }
    private static func drive(supervisor: ChatterboxMacLocalWorkerSupervisor, authority: ChapterDurableIntentAuthority,
                              session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                              event: @escaping @Sendable (Event) async -> Void) async {
        var handled = Set<String>(), delay = 1
        while !Task.isCancelled {
            do {
                let snapshot = try await authority.wantedSnapshot(session: session, gate: gate)
                var current = Set<String>()
                for readSet in snapshot.readSets { current.insert(try ChapterLocalCompletion.lookupKey(for: readSet)) }
                handled.formIntersection(current)
                await event(.snapshot(snapshot.readSets.count)); delay = 1
                for readSet in snapshot.readSets {
                    try Task.checkCancellation()
                    let key = try ChapterLocalCompletion.lookupKey(for: readSet)
                    guard !handled.contains(key) else { continue }
                    await event(.rendering(readSet.intent.request))
                    do {
                        _ = try await supervisor.renderAndPublish(readSet, authority: authority)
                        handled.insert(key); await event(.completed)
                    } catch {
                        if Task.isCancelled { return }
                        if error as? ChatterboxMacWorkerError == .closed || error as? ChapterWorkerError == .accountMismatch { return }
                        if error as? ChapterLocalIntentError != .staleIntent { handled.insert(key) }
                        let code: ChapterServiceFailure.Code = error is ChapterStorageBudgetError ? .storage : .renderer
                        await event(.failed(.init(code: code, recovery: code == .storage ? .freeSpace : .retry)))
                        if !(await supervisor.acceptingClaims()) { return }
                    }
                }
            } catch {
                if Task.isCancelled || error as? ChapterWorkerError == .accountMismatch { return }
                await event(.unavailable); delay = min(delay * 2, 30)
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }
}
#endif
