import Foundation
import LibroxChapterWorker

public enum ChatterboxLocalPreparedServiceError: Error, Equatable { case closed, busy, notSubmitted, notReady, staleCommand }

/// Concrete Reader owner for the local prepared service. The SDK host factory
/// supplies an actual prepared-backend catalog, authorized paths and owned stores.
/// There is intentionally no public constructor accepting arbitrary model hashes.
public actor ChatterboxLocalPreparedChapterService: ChatterboxPreparedChapterService {
    private struct Operation {
        let cancel: @Sendable () -> Void
        let joined: Task<Void, Never>
        let key: String?
    }
    private struct Subscription {
        let request: ChapterRenderRequest
        var sequence: UInt64 = 0
        let continuation: AsyncThrowingStream<ChapterServiceUpdate, Error>.Continuation
    }
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let outbox: ChapterDemandOutbox
    private let publicationBudget, artifactBudget: ChapterArtifactStorageBudget
    private let sources, plans, publications, artifacts: URL
    private let catalogProvider: @Sendable (ChapterAccountSession) async throws -> ChatterboxStockCatalog
    private var operations: [UUID: Operation] = [:]
    private var subscriptions: [UUID: Subscription] = [:]
    private var playable: [String: ChapterReaderArtifactAcceptance] = [:]
    private var observer: Task<Void, Never>?
    private var observerID: UUID?
    private var closeTask: Task<Void, Error>?
    private var closing = false
    private var command = UUID()

    package init(session: ChapterAccountSession, gate: ChapterAccountSessionGate, outbox: ChapterDemandOutbox,
                 publicationBudget: ChapterArtifactStorageBudget, artifactBudget: ChapterArtifactStorageBudget,
                 sourceDirectory: URL, planDirectory: URL, publicationDirectory: URL, artifactDirectory: URL,
                 catalog: @escaping @Sendable (ChapterAccountSession) async throws -> ChatterboxStockCatalog) {
        self.session = session; self.gate = gate; self.outbox = outbox
        self.publicationBudget = publicationBudget; self.artifactBudget = artifactBudget
        sources = sourceDirectory; plans = planDirectory; publications = publicationDirectory; artifacts = artifactDirectory
        catalogProvider = catalog
    }
    deinit { observer?.cancel(); for operation in operations.values { operation.cancel() } }

    /// Opens the actual Reader owner. The catalog endpoint must be the SDK's
    /// prepared Worker or qualified cloud transport, never guessed model data.
    /// Cold construction performs no model work or CloudKit operation.
    public static func open(session: ChapterAccountSession, gate: ChapterAccountSessionGate, deviceID: UUID,
                            directories: ChatterboxLocalReaderDirectories,
                            publicationPolicy: ChapterStorageBudgetPolicy, artifactPolicy: ChapterStorageBudgetPolicy,
                            catalog: @escaping @Sendable (ChapterAccountSession) async throws -> ChatterboxStockCatalog) async throws -> ChatterboxLocalPreparedChapterService {
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            try directories.validate()
            let publications = try ChapterArtifactStorageBudget(controlDirectory: directories.sources,
                managedDirectories: [directories.sources, directories.plans], policy: publicationPolicy)
            var artifacts: ChapterArtifactStorageBudget?, outbox: ChapterDemandOutbox?
            do {
                let audio = try ChapterArtifactStorageBudget(controlDirectory: directories.artifacts,
                    managedDirectories: [directories.artifacts], policy: artifactPolicy)
                artifacts = audio
                let journal = try await ChapterDemandOutbox.openWithDurableAuthority(directory: directories.outbox,
                    authorityDirectory: directories.authority, accountPartition: session.accountPartition, deviceID: deviceID)
                outbox = journal
                try directories.validate()
                try await gate.validate(session); try Task.checkCancellation()
                return ChatterboxLocalPreparedChapterService(session: session, gate: gate, outbox: journal,
                    publicationBudget: publications, artifactBudget: audio, sourceDirectory: directories.sources,
                    planDirectory: directories.plans, publicationDirectory: directories.publications, artifactDirectory: directories.artifacts,
                    catalog: catalog)
            } catch {
                await outbox?.close(); try? await artifacts?.close(); try? await publications.close(); throw error
            }
        }
        let service = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do { try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation(); return service }
        catch { try? await service.close(session: session); throw error }
    }

    /// Immutable local routing metadata, not the Reader journal handle or a
    /// cross-process credential. The host authorizes its read-only directory.
    public func localIntentDescriptor(session: ChapterAccountSession) async throws -> ChapterDurableIntentDescriptor {
        try await perform(session: session, key: nil) { [outbox] in try await outbox.durableIntentDescriptor() }
    }

    public func catalog(session: ChapterAccountSession) async throws -> ChatterboxStockCatalog {
        try await perform(session: session, key: nil) { [catalogProvider] in
            let catalog = try await catalogProvider(session)
            guard catalog.session == session else { throw ChapterWorkerError.accountMismatch }
            return try .init(session: session, voices: catalog.voices, deliveryDomain: .local)
        }
    }
    public func submit(_ prepared: ChatterboxPreparedChapterSubmission) async throws -> ChapterDemandReceipt {
        let s = prepared.submission, key = try s.request.renderKey()
        try beginCommand(session: s.session, key: key)
        let stamp = command
        try await validate(s.session)
        let catalog = try await catalog(session: s.session)
        guard command == stamp else { throw ChatterboxLocalPreparedServiceError.staleCommand }
        try validate(prepared, catalog: catalog)
        let intent = try await perform(session: s.session, key: key, commandStamp: stamp) { [outbox, gate, publicationBudget, sources, plans] in
            try await publicationBudget.requireExactManagedDirectories([sources, plans])
            return try await ChatterboxLocalSubmissionAdmission.submit(prepared.plan, submission: s, gate: gate,
                outbox: outbox, budget: publicationBudget, sourceDirectory: sources, planDirectory: plans)
        }
        guard command == stamp else { throw ChatterboxLocalPreparedServiceError.staleCommand }
        let receipt = try localReceipt(intent)
        emit(key: key, state: .localIntent, receipt: receipt)
        try await validate(s.session)
        guard command == stamp else { throw ChatterboxLocalPreparedServiceError.staleCommand }
        return receipt
    }
    public func cancel(request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChapterDemandReceipt {
        let key = try request.renderKey()
        guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try beginCommand(session: session, key: key); let stamp = command
        try await validate(session)
        playable.removeValue(forKey: key)
        // Cancellation is control-plane work: ordinary artifact allowances and
        // the ordinary operation limit cannot block it.
        let intent = try await perform(session: session, key: key, control: true, commandStamp: stamp) { [outbox] in
            try await outbox.setDemand(false, for: request)
        }
        guard command == stamp else { throw ChatterboxLocalPreparedServiceError.staleCommand }
        let receipt = try localReceipt(intent)
        emit(key: key, state: .cancelled, receipt: receipt)
        try await validate(session)
        return receipt
    }
    public func preparedSubmission(for request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChatterboxPreparedChapterSubmission? {
        try await perform(session: session, key: try request.renderKey()) { [outbox, gate, sources, plans] in
            try await ChatterboxLocalPreparedSubmission.recover(for: request, session: session, gate: gate,
                outbox: outbox, sourceDirectory: sources, planDirectory: plans)
        }
    }
    public func download(_ prepared: ChatterboxPreparedChapterSubmission) async throws -> ChapterLocalArtifact {
        let s = prepared.submission, key = try s.request.renderKey()
        let stamp = command
        try await validate(s.session)
        // Exact stored options, not a caller-made replacement plan.
        guard let stored = try await preparedSubmission(for: s.request, session: s.session),
              stored.plan.encoded() == prepared.plan.encoded(),
              Data(stored.submission.originalText.utf8) == Data(s.originalText.utf8) else { throw ChapterWorkerError.invalidManifest }
        let accepted = try await perform(session: s.session, key: key, commandStamp: stamp) { [outbox, gate, publicationBudget, artifactBudget, sources, plans, publications, artifacts] in
            try await publicationBudget.requireExactManagedDirectories([sources, plans])
            try await artifactBudget.requireExactManagedDirectories([artifacts])
            guard let readSet = try await outbox.wantedReadSet(for: s.request) else { throw ChapterLocalIntentError.staleIntent }
            let authority = ChapterReaderIntentAuthority(outbox: outbox, session: s.session, gate: gate)
            let reference: ChapterLocalHandoffReference
            if let completed = try await ChapterLocalCompletion.receiveIfPresent(for: readSet, session: s.session,
                gate: gate, authority: authority, directory: publications) { reference = completed.handoffReference }
            else if let retained = try await outbox.retainedHandoff(for: s.request) { reference = retained.reference }
            else { throw ChatterboxLocalPreparedServiceError.notReady }
            return try await ChapterReaderStorageAdmission.receiveAndAccept(reference, submission: s, readSet: readSet,
                gate: gate, outbox: outbox, budget: artifactBudget, publicationDirectory: publications, storageDirectory: artifacts)
        }
        guard try await outbox.validateCurrent(accepted.readSet) else { throw ChapterLocalIntentError.staleIntent }
        try await validate(s.session)
        guard command == stamp else { throw ChatterboxLocalPreparedServiceError.staleCommand }
        playable[key] = accepted
        emit(key: key, state: .playable(accepted.artifact), receipt: try localReceipt(accepted.readSet.intent))
        try await validate(s.session)
        guard try await outbox.validateCurrent(accepted.readSet) else { throw ChapterLocalIntentError.staleIntent }
        try await validate(s.session)
        return accepted.artifact
    }
    public func updates(for request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> AsyncThrowingStream<ChapterServiceUpdate, Error> {
        try await validate(session); try request.validate()
        guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard subscriptions.count < 64 else { throw ChatterboxLocalPreparedServiceError.busy }
        let id = UUID(), pair = AsyncThrowingStream<ChapterServiceUpdate, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscription(id) } }
        subscriptions[id] = .init(request: request, continuation: pair.continuation)
        do {
            try await perform(session: session, key: try request.renderKey()) { [weak self] in await self?.refreshSubscription(id) }
            if let old = observer, old.isCancelled {
                let oldID = observerID
                await old.value
                if observerID == oldID { observer = nil; observerID = nil }
            }
            try await validate(session)
        } catch { removeSubscription(id); throw error }
        if observer == nil, !subscriptions.isEmpty {
            observerID = UUID()
            observer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    await self?.refreshSubscriptions()
                }
            }
        }
        return pair.stream
    }
    public func close(session: ChapterAccountSession) async throws {
        guard session == self.session else { throw ChapterWorkerError.accountMismatch }
        if let closeTask { try await closeTask.value; return }
        closing = true; command = UUID()
        let observer = self.observer; observer?.cancel(); self.observer = nil; observerID = nil
        let pending = Array(operations.values)
        for operation in pending { operation.cancel() }
        for subscription in subscriptions.values { subscription.continuation.finish() }
        subscriptions.removeAll(); playable.removeAll()
        let task = Task { [outbox, publicationBudget, artifactBudget] in
            for operation in pending { await operation.joined.value }
            await observer?.value
            await outbox.close()
            // Readers own only their budgets; never close the Worker here.
            var first: Error?
            do { try await publicationBudget.close() } catch { first = error }
            do { try await artifactBudget.close() } catch { if first == nil { first = error } }
            if let first { throw first }
        }
        closeTask = task
        try await task.value
    }

    private func validate(_ supplied: ChapterAccountSession) async throws {
        guard !closing else { throw ChatterboxLocalPreparedServiceError.closed }
        guard supplied == session else { throw ChapterWorkerError.accountMismatch }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard !closing else { throw ChatterboxLocalPreparedServiceError.closed }
    }
    private func perform<T: Sendable>(session: ChapterAccountSession, key: String?, control: Bool = false,
                                      commandStamp: UUID? = nil,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await validate(session)
        if let commandStamp, command != commandStamp { throw ChatterboxLocalPreparedServiceError.staleCommand }
        guard operations.count < (control ? 48 : 32) else { throw ChatterboxLocalPreparedServiceError.busy }
        let id = UUID(), task = Task { try await operation() }
        let joined = Task { _ = await task.result }
        operations[id] = .init(cancel: { task.cancel() }, joined: joined, key: key)
        defer { operations.removeValue(forKey: id) }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await validate(session)
        return value
    }
    private func beginCommand(session: ChapterAccountSession, key: String) throws {
        guard !closing else { throw ChatterboxLocalPreparedServiceError.closed }
        guard session == self.session else { throw ChapterWorkerError.accountMismatch }
        try Task.checkCancellation()
        command = UUID()
        for operation in operations.values where operation.key == key { operation.cancel() }
    }
    private func validate(_ prepared: ChatterboxPreparedChapterSubmission, catalog: ChatterboxStockCatalog) throws {
        guard let voice = catalog.voices.first, voice.availability == .available else { throw ChatterboxLocalPreparedServiceError.notReady }
        let options = try prepared.plan.restore(source: prepared.submission.originalText)
        guard voice.deliveryFormats.contains(options.delivery) else { throw ChapterServiceError.unsupportedPolicy }
        let expected = try voice.descriptor.prepareChapter(source: prepared.submission.request.source, options: options, session: session)
        guard try expected.submission.request.renderKey() == prepared.submission.request.renderKey() else { throw ChapterWorkerError.invalidManifest }
    }
    private func localReceipt(_ intent: ChapterDemandIntent) throws -> ChapterDemandReceipt {
        try .init(request: intent.request, session: session, deviceID: intent.deviceID,
                  intentRevision: intent.revision, wanted: intent.wanted, delivery: .localIntent)
    }
    private func refreshSubscriptions() async {
        for id in Array(subscriptions.keys) { if Task.isCancelled || closing { return }; await refreshSubscription(id) }
    }
    private func refreshSubscription(_ id: UUID) async {
        guard let initial = subscriptions[id], !closing else { return }
        let stamp = command
        do {
            try await validate(session)
            guard let intent = try await outbox.currentIntent(for: initial.request) else { throw ChatterboxLocalPreparedServiceError.notSubmitted }
            try await validate(session)
            let key = try initial.request.renderKey(), receipt = try localReceipt(intent)
            let state: ChapterServiceState
            if !intent.wanted { playable.removeValue(forKey: key); state = .cancelled }
            else if let accepted = playable[key], try await outbox.validateCurrent(accepted.readSet) { state = .playable(accepted.artifact) }
            else if let readSet = try await outbox.wantedReadSet(for: initial.request),
                    let completed = try await ChapterLocalCompletion.receiveIfPresent(for: readSet, session: session,
                        gate: gate, authority: ChapterReaderIntentAuthority(outbox: outbox, session: session, gate: gate), directory: publications),
                    let source = try await ChatterboxLocalPreparedSubmission.recover(for: initial.request, session: session,
                        gate: gate, outbox: outbox, sourceDirectory: sources, planDirectory: plans) {
                state = .remoteReady(try await ChapterLocalHandoff.inspectManifest(completed.handoffReference,
                    submission: source.submission, gate: gate, directory: publications))
            } else { state = .localIntent }
            try await validate(session)
            guard try await outbox.currentIntent(for: initial.request) == intent else { return }
            try await validate(session)
            guard var subscription = subscriptions[id], !closing, command == stamp else { return }
            guard subscription.sequence < .max else { throw ChapterServiceError.invalidUpdate }
            subscription.sequence += 1
            let update = try ChapterServiceUpdate(request: initial.request, session: session, sequence: subscription.sequence,
                state: state, demandReceipt: receipt)
            subscriptions[id] = subscription; subscription.continuation.yield(update)
        } catch {
            if !Task.isCancelled, !closing, error as? ChapterLocalIntentError == .staleIntent { return }
            if let subscription = subscriptions.removeValue(forKey: id) { subscription.continuation.finish(throwing: error) }
            if subscriptions.isEmpty { observer?.cancel() }
        }
    }
    private func removeSubscription(_ id: UUID) {
        subscriptions.removeValue(forKey: id)
        // Retain the cancelled task until joined by close or a subsequent
        // subscription. Never discard ownership while its file IO can run.
        if subscriptions.isEmpty { observer?.cancel() }
    }
    private func emit(key: String, state: ChapterServiceState, receipt: ChapterDemandReceipt) {
        guard !closing else { return }
        for id in Array(subscriptions.keys) {
            guard var subscription = subscriptions[id], (try? subscription.request.renderKey()) == key else { continue }
            do {
                guard subscription.sequence < .max else { throw ChapterServiceError.invalidUpdate }
                subscription.sequence += 1
                let update = try ChapterServiceUpdate(request: subscription.request, session: session,
                    sequence: subscription.sequence, state: state, demandReceipt: receipt)
                subscriptions[id] = subscription; subscription.continuation.yield(update)
            } catch {
                subscription.continuation.finish(throwing: error); subscriptions.removeValue(forKey: id)
            }
        }
    }
}
