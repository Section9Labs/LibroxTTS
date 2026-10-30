#if os(macOS)
import Foundation
import Testing
import Darwin
@testable import LibroxChapterWorker
@testable import LibroxChatterboxPlanning
import LibroxChatterbox
@testable import ChatterboxCoreML
@testable import LibroxChatterboxMac

private actor WorkerSignals {
    private var signals: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var renderer: ChatterboxMacResidentRenderer?
    func recordRenderer(_ renderer: ChatterboxMacResidentRenderer) { self.renderer = renderer }
    var workerSession: ChapterAccountSession?
    func recordWorkerSession(_ session: ChapterAccountSession) { workerSession = session }
    var loads = 0, streams = 0
    func counts() -> (Int, Int) { (loads, streams) }
    func loaded() { loads += 1 }
    func streamed() { streams += 1 }
    func signal(_ name: String) { signals.insert(name); for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.resume() } }
    func has(_ name: String) -> Bool { signals.contains(name) }
    func wait(_ name: String) async { if !signals.contains(name) { await withCheckedContinuation { waiters[name, default: []].append($0) } } }
}
private actor WorkerHookCounter { var count = 0; func next() -> Int { count += 1; return count } }
private struct WorkerSyntheticBackend: ResidentChapterBackend {
    let profile: String
    let modelSHA256 = String(repeating: "b", count: 64), conditioningSHA256 = String(repeating: "c", count: 64)
    let voice: URL, signals: WorkerSignals
    let pauseRender: Bool
    var disabledOnCancel = false
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL,
                receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        await signals.streamed(); await signals.signal("render-entered")
        do {
            if pauseRender {
                await withTaskCancellationHandler { await signals.wait("render-release") } onCancel: { Task { await signals.signal("render-cancelled") } }
            }
            if disabledOnCancel, Task.isCancelled { throw ChapterWorkerJournalError.disabled }
            try Task.checkCancellation()
            let narrator = ChatterboxNarrator(rendering: { _ in try ChatterboxAudioChunk(samples: (0..<2401).map { Float(sin(Double($0) * 0.05)) * 0.25 }) })
            let session = try ChatterboxBookSession(narrator: narrator, cacheDirectory: cache,
                modelManifestSHA256: String(repeating: "a", count: 64), rendererProfile: profile)
            do {
                try await session.streamChapter(request.text, language: request.language, narratorID: "stock", conditioningFiles: ["stock": voice],
                    direction: request.direction, grouping: request.grouping, seed: request.seed, performanceDirections: request.performanceDirections, receive: receive)
            } catch { try? await narrator.unload(); throw error }
            try await narrator.unload(); await signals.signal("render-exited")
        } catch { await signals.signal("render-exited"); throw error }
    }
}
private final class LocalWorkerFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-worker-" + UUID().uuidString)
    let readerOutbox: URL, readerAuthority: URL, readerCustody: URL, voice: URL
    let directories: ChatterboxMacWorkerDirectories
    let readerGate = ChapterAccountSessionGate(), workerGate = ChapterAccountSessionGate(), signals = WorkerSignals()
    let partition = String(repeating: "a", count: 64), device = UUID(), workerID = UUID()
    let text = "Keep going."
    init() throws {
        readerOutbox = root.appendingPathComponent("Reader-Outbox"); readerAuthority = root.appendingPathComponent("Reader-Authority")
        readerCustody = root.appendingPathComponent("Reader-Custody"); voice = root.appendingPathComponent("synthetic.safetensors")
        let source = root.appendingPathComponent("Reader-Sources"), plans = root.appendingPathComponent("Reader-Plans")
        let state = root.appendingPathComponent("Worker-State"), exports = root.appendingPathComponent("Worker-Exports")
        let custody = root.appendingPathComponent("Worker-Custody"), published = root.appendingPathComponent("Worker-Published")
        for url in [root, readerOutbox, readerAuthority, readerCustody, source, plans, state, exports, custody, published] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        directories = try .init(sourcePublications: source, planPublications: plans, state: state, exports: exports, custody: custody, publications: published)
        try Conditionals(speakerEmb: Array(repeating: 0, count: 256), condPromptSpeechTokens: [1],
            genEmbedding: Array(repeating: 0, count: 192), promptTokens: [1], promptFeat: Array(repeating: 0, count: 80)).write(to: voice)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func setup(pauseLoad: Bool = false, pauseRender: Bool = false, mismatchedProfile: Bool = false, disabledOnCancel: Bool = false, hooks: LocalWorkerLifecycleHooks = .init(), artifactBudget: ChapterArtifactStorageBudget? = nil) async throws -> (ChatterboxMacLocalWorker, ChapterSubmission, ChapterDemandOutbox, ChapterIntentReadSet, ChapterDurableIntentAuthority) {
        let reader = try await readerGate.open(accountPartition: partition), worker = try await workerGate.open(accountPartition: partition)
        await signals.recordWorkerSession(worker)
        let directions = try ChatterboxPerformanceDirections(source: text, annotations: [
            .init(range: NSRange(location: 0, length: text.utf16.count), originalText: text,
                performance: .init(delivery: .urgent, strength: .strong), controls: .init(exaggeration: 0.9, guidance: 0.3, temperature: 0.8))
        ], scope: .chapterV1)
        let options = try ChatterboxMacChapterRequest(text: text, language: "en", performanceDirections: directions, seed: 4242)
        let fake = WorkerSyntheticBackend(profile: "synthetic-local-worker-1", voice: voice, signals: signals, pauseRender: pauseRender)
        let sourceID = try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: "chapter:1",
            textSHA256: ChatterboxMacChapterRequest.hash(Data(text.utf8)), extractionRevision: "synthetic-1", utf16Length: text.utf16.count)
        // Reader fixture metadata only. Production binding/catalog authority remains separate.
        let binding = try ChatterboxMacChapterBinding(source: sourceID, localRequest: options, rendererID: UUID(), backend: fake, session: reader)
        let submission = binding.submission
        let source = try await ChapterLocalSource.publish(submission, gate: readerGate, directory: directories.sourcePublications)
        let plan = try await ChatterboxLocalRenderPlan.publish(.init(request: options), submission: submission, source: source,
            gate: readerGate, directory: directories.planPublications)
        let outbox = try await ChapterDemandOutbox.openWithDurableAuthority(directory: readerOutbox, authorityDirectory: readerAuthority,
            accountPartition: partition, deviceID: device)
        _ = try await outbox.setDemand(true, for: submission.request, source: source, renderPlan: plan)
        let readSet = try await #require(outbox.wantedReadSet(for: submission.request))
        let authority = try await ChapterDurableIntentAuthority(directory: readerAuthority, descriptor: outbox.durableIntentDescriptor())
        let s = signals, v = voice
        let renderer = ChatterboxMacResidentRenderer(testFactory: {
            await s.loaded(); await s.signal("load-entered")
            if pauseLoad {
                await withTaskCancellationHandler { await s.wait("load-release") } onCancel: { Task { await s.signal("load-cancelled") } }
            }
            try Task.checkCancellation()
            return WorkerSyntheticBackend(profile: mismatchedProfile ? "wrong-profile" : "synthetic-local-worker-1", voice: v, signals: s, pauseRender: pauseRender, disabledOnCancel: disabledOnCancel)
        })
        await signals.recordRenderer(renderer)
        let journal = try ChapterWorkerJournal(directory: directories.state, accountPartition: partition, workerID: workerID)
        return (ChatterboxMacLocalWorker(renderer: renderer, journal: journal, session: worker, gate: workerGate, directories: directories, hooks: hooks, artifactBudget: artifactBudget), submission, outbox, readSet, authority)
    }
    func budget(maximum: UInt64 = ChatterboxMacWorkerStoragePolicy.freshAdmissionBytes + 16 * 1024 * 1024) throws -> ChapterArtifactStorageBudget {
        try .init(controlDirectory: directories.exports, managedDirectories: [directories.exports, directories.custody, directories.publications],
            policy: .init(maximumManagedBytes: maximum, minimumAvailableBytes: 0, maximumReservations: 1))
    }
    func readerService(_ submission: ChapterSubmission, outbox: ChapterDemandOutbox,
                       available: Bool = true, maximumPublicationBytes: UInt64 = 16 * 1024 * 1024,
                       beforeCatalog: @escaping @Sendable () async throws -> Void = {}) throws -> ChatterboxLocalPreparedChapterService {
        let publicationBudget = try ChapterArtifactStorageBudget(controlDirectory: directories.sourcePublications,
            managedDirectories: [directories.sourcePublications, directories.planPublications],
            policy: .init(maximumManagedBytes: maximumPublicationBytes, minimumAvailableBytes: 0))
        let artifacts = try ChapterArtifactStorageBudget(controlDirectory: readerCustody, managedDirectories: [readerCustody],
            policy: .init(maximumManagedBytes: 16 * 1024 * 1024, minimumAvailableBytes: 0))
        let descriptor = try ChatterboxStockVoiceDescriptor(modelSHA256: submission.request.recipe.modelSHA256,
            conditioningSHA256: submission.request.recipe.conditioningSHA256, rendererProfile: submission.request.recipe.rendererProfile)
        return ChatterboxLocalPreparedChapterService(session: submission.session, gate: readerGate, outbox: outbox,
            publicationBudget: publicationBudget, artifactBudget: artifacts, sourceDirectory: directories.sourcePublications,
            planDirectory: directories.planPublications, publicationDirectory: directories.publications, artifactDirectory: readerCustody) { session in
                try await beforeCatalog()
                return try .init(session: session, voices: [.init(descriptor: descriptor, availability: available ? .available : .unavailable)])
            }
    }
    func bundles() throws -> [URL] { try FileManager.default.contentsOfDirectory(at: directories.publications, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != "artifact-budget.lock" } }
}

@Suite(.serialized) struct LocalWorkerTests {
    @Test func fullOwnedSyntheticChainPublishesAndReaderAdoptsActualAAC() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, readSet, authority) = try await f.setup()
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await worker.render(readSet, authority: authority) }
        try await worker.enable()
        let output = try await worker.render(readSet, authority: authority)
        #expect(!output.reusedCompletedAudio && output.decodedFrames > 0)
        #expect(output.completeWallSeconds >= output.completeWarmSeconds && output.completeWarmSeconds >= 0)
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .published)
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        let received = try await ChapterLocalHandoff.receive(output.reference, submission: submission, gate: f.readerGate,
            directory: f.directories.publications, storageDirectory: f.readerCustody)
        #expect(received.codec == .aac64)
        let accepted = try await outbox.acceptVerifiedHandoff(received, submission: submission, readSet: readSet, gate: f.readerGate)
        #expect(accepted.reference == output.reference)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        try await worker.shutdown(); await outbox.close()
        #expect(await worker.state() == .closed)
    }
    @Test func disabledLoadingJoinsBeforeOwnershipReleaseEvenWhenStopCallerCancelled() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, readSet, authority) = try await f.setup(pauseLoad: true)
        try await worker.enable()
        let render = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("load-entered")
        let stop = Task { try await worker.disable(); await f.signals.signal("stop-returned") }; stop.cancel()
        await f.signals.wait("load-cancelled")
        #expect(await !f.signals.has("stop-returned"))
        #expect(throws: ChapterWorkerJournalError.alreadyOpen) { try ChapterWorkerJournal(directory: f.directories.state, accountPartition: f.partition, workerID: f.workerID) }
        await #expect(throws: ChatterboxMacWorkerError.busy) { try await worker.enable() }
        await f.signals.signal("load-release"); try await stop.value
        await #expect(throws: CancellationError.self) { try await render.value }
        #expect(await worker.state() == .disabled)
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .interrupted)
        #expect(try f.bundles().isEmpty)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func disableDuringRenderHoldsClaimUntilActualBackendExits() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, readSet, authority) = try await f.setup(pauseRender: true)
        try await worker.enable(); let render = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("render-entered")
        let stop = Task { try await worker.disable(); await f.signals.signal("stop-returned") }
        await f.signals.wait("render-cancelled")
        #expect(await !f.signals.has("stop-returned"))
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .rendering)
        #expect(throws: ChapterWorkerJournalError.alreadyOpen) { try ChapterWorkerJournal(directory: f.directories.state, accountPartition: f.partition, workerID: f.workerID) }
        await f.signals.signal("render-release"); try await stop.value
        await #expect(throws: CancellationError.self) { try await render.value }
        #expect(await f.signals.has("render-exited"))
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .interrupted)
        #expect(try f.bundles().isEmpty)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func callerCancellationJoinsAndKeepsResidentRendererForExplicitNextJob() async throws {
        let f = try LocalWorkerFixture(), (worker, _, outbox, readSet, authority) = try await f.setup(pauseRender: true)
        try await worker.enable(); let render = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("render-entered"); render.cancel(); await f.signals.wait("render-cancelled")
        await #expect(throws: ChatterboxMacWorkerError.busy) { try await worker.render(readSet, authority: authority) }
        await f.signals.signal("render-release")
        await #expect(throws: CancellationError.self) { try await render.value }
        #expect(await worker.state() == .waiting)
        let next = try await worker.render(readSet, authority: authority, recovery: .renderFresh)
        #expect(!next.reusedCompletedAudio)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 2)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func synchronousLifecycleFenceStopsAdmissionAndSignalsBeforeAsyncJoin() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, readSet, authority) = try await f.setup(pauseRender: true)
        try await worker.enable(); let render = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("render-entered")
        let sameTurnFence: @Sendable () -> Void = { worker.stopClaims() }
        sameTurnFence() // Compiles and executes without a Task or actor hop.
        await f.signals.wait("render-cancelled")
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await worker.render(readSet, authority: authority) }
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .rendering)
        #expect(throws: ChapterWorkerJournalError.alreadyOpen) { try ChapterWorkerJournal(directory: f.directories.state, accountPartition: f.partition, workerID: f.workerID) }
        let join = Task { try await worker.disable() }
        await f.signals.signal("render-release"); try await join.value
        await #expect(throws: CancellationError.self) { try await render.value }
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .interrupted)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func currentReaderCancellationRejectsBoundPassageBeforePublication() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, readSet, authority) = try await f.setup(pauseRender: true)
        try await worker.enable(); let render = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("render-entered")
        _ = try await outbox.setDemand(false, for: submission.request)
        await f.signals.signal("render-release")
        await #expect(throws: ChapterLocalIntentError.staleIntent) { try await render.value }
        #expect(try f.bundles().isEmpty)
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .interrupted)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func exactCompletedRecoverySkipsSynthesisAndCorruptionDoesNotSilentlyRerender() async throws {
        let f = try LocalWorkerFixture(), (worker, _, outbox, readSet, authority) = try await f.setup()
        try await worker.enable()
        let first = try await worker.render(readSet, authority: authority)
        let second = try await worker.render(readSet, authority: authority)
        #expect(second.reusedCompletedAudio && second.reference == first.reference)
        #expect(await f.signals.streams == 1)
        let audio = f.directories.publications.appendingPathComponent(first.reference.identifier).appendingPathComponent("audio")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
        try Data("corrupt".utf8).write(to: audio)
        await #expect(throws: (any Error).self) { try await worker.render(readSet, authority: authority) }
        #expect(await f.signals.streams == 1)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func cachedAudioCannotHideAPlanWithInconsistentGroupingFingerprint() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, original, authority) = try await f.setup()
        try await worker.enable()
        _ = try await worker.render(original, authority: authority)
        let file = f.directories.planPublications.appendingPathComponent(original.renderPlanReference.identifier + ".json")
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let encoded = try #require(envelope["plan"] as? String)
        let planBytes = try #require(Data(base64Encoded: encoded))
        var payload = try #require(JSONSerialization.jsonObject(with: planBytes) as? [String: Any])
        payload["grouping"] = "compatible-narration"; payload["maximumCharacters"] = 160
        envelope["plan"] = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]).base64EncodedString()
        let bytes = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = ChatterboxMacChapterRequest.hash(bytes)
        try bytes.write(to: f.directories.planPublications.appendingPathComponent(digest + ".json"))
        let source = try await ChapterLocalSource.publish(submission, gate: f.readerGate, directory: f.directories.sourcePublications)
        let inconsistent = ChapterLocalRenderPlanPublication(reference: try .init(identifier: digest), sourceReference: source.reference,
            accountPartition: f.partition, renderKey: try submission.request.renderKey())
        _ = try await outbox.setDemand(true, for: submission.request, source: source, renderPlan: inconsistent)
        let fresh = try await #require(outbox.wantedReadSet(for: submission.request))
        await #expect(throws: ChatterboxChapterRenderPlanError.recipeMismatch) { try await worker.render(fresh, authority: authority) }
        #expect(await f.signals.streams == 1)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func wrongBackendRecipeNeverBeginsSynthesis() async throws {
        let f = try LocalWorkerFixture(), (worker, _, outbox, readSet, authority) = try await f.setup(mismatchedProfile: true)
        try await worker.enable()
        await #expect(throws: ChatterboxMacRenderPlanError.recipeMismatch) { try await worker.render(readSet, authority: authority) }
        #expect(await f.signals.streams == 0)
        #expect(try f.bundles().isEmpty)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func disabledJournalOutcomeIsInterruptionAndUnchangedIntentCanRunAfterEnable() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, readSet, authority) = try await f.setup(pauseRender: true, disabledOnCancel: true)
        try await worker.enable(); let run = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("render-entered")
        let stop = Task { try await worker.disable() }
        await f.signals.wait("render-cancelled"); await f.signals.signal("render-release")
        try await stop.value
        await #expect(throws: ChapterWorkerJournalError.disabled) { try await run.value }
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .interrupted)
        try await worker.enable()
        _ = try await worker.render(readSet, authority: authority, recovery: .renderFresh)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func concurrentStopsBlockEnableUntilEveryStopContinuationFinishes() async throws {
        let f = try LocalWorkerFixture(), counter = WorkerHookCounter(), signals = f.signals
        let hooks = LocalWorkerLifecycleHooks(beforeStop: {
            let count = await counter.next()
            await signals.signal("stop-entered-\(count)")
            if count <= 2 { await signals.wait("stop-release-\(count)") }
        })
        let (worker, _, outbox, _, _) = try await f.setup(hooks: hooks)
        try await worker.enable()
        let first = Task { try await worker.disable() }; await signals.wait("stop-entered-1")
        let second = Task { try await worker.disable() }; await signals.wait("stop-entered-2")
        await signals.signal("stop-release-1"); try await first.value
        await #expect(throws: ChatterboxMacWorkerError.busy) { try await worker.enable() }
        await signals.signal("stop-release-2"); try await second.value
        try await worker.enable(); #expect(await worker.state() == .waiting)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func pausedOlderEnableCannotReactivateAfterAStop() async throws {
        let f = try LocalWorkerFixture(), counter = WorkerHookCounter(), signals = f.signals
        let hooks = LocalWorkerLifecycleHooks(beforeEnableCommit: {
            if await counter.next() == 1 { await signals.signal("enable-entered"); await signals.wait("enable-release") }
        })
        let (worker, _, outbox, readSet, authority) = try await f.setup(hooks: hooks)
        let enable = Task { try await worker.enable() }; await signals.wait("enable-entered")
        try await worker.disable()
        await signals.signal("enable-release")
        await #expect(throws: CancellationError.self) { try await enable.value }
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await worker.render(readSet, authority: authority) }
        try await worker.enable(); #expect(await worker.state() == .waiting)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func cancelledEnableCallerCannotActivateClaimsAfterItsAwait() async throws {
        let f = try LocalWorkerFixture(), signals = f.signals, count = WorkerHookCounter()
        let hooks = LocalWorkerLifecycleHooks(afterEnableClaims: {
            if await count.next() == 1 { await signals.signal("enable-claims-entered"); await signals.wait("enable-claims-release") }
        })
        let (worker, _, outbox, readSet, authority) = try await f.setup(hooks: hooks)
        let enable = Task { try await worker.enable() }
        await signals.wait("enable-claims-entered"); enable.cancel(); await signals.signal("enable-claims-release")
        await #expect(throws: CancellationError.self) { try await enable.value }
        #expect(await worker.state() == .disabled)
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await worker.render(readSet, authority: authority) }
        try await worker.enable(); _ = try await worker.render(readSet, authority: authority)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func newAccountEpochDuringEnableCannotActivateOldWorker() async throws {
        let f = try LocalWorkerFixture(), signals = f.signals
        let hooks = LocalWorkerLifecycleHooks(afterEnableClaims: {
            await signals.signal("epoch-enable-entered"); await signals.wait("epoch-enable-release")
        })
        let (worker, _, outbox, readSet, authority) = try await f.setup(hooks: hooks)
        let enable = Task { try await worker.enable() }
        await signals.wait("epoch-enable-entered")
        _ = try await f.workerGate.open(accountPartition: f.partition)
        await signals.signal("epoch-enable-release")
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await enable.value }
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await worker.render(readSet, authority: authority) }
        #expect(await f.signals.loads == 0)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func productionConstructorRejectsForeignVoiceModelBeforeAnyLoad() async throws {
        let f = try LocalWorkerFixture(), (synthetic, _, outbox, readSet, authority) = try await f.setup()
        try await synthetic.shutdown()
        let own = try await f.workerGate.open(accountPartition: f.partition)
        let assets = ChatterboxMacModelAssets(metallib: f.voice, acousticCheckpoint: f.voice, decoderWeights: f.voice,
            decoderOracle: f.voice, frontendDirectory: f.root, stockConditioning: f.voice)
        let budget = try f.budget()
        let worker = try ChatterboxMacLocalWorker(assets: assets, workerID: f.workerID, session: own, gate: f.workerGate, directories: f.directories, artifactBudget: budget)
        try await worker.enable()
        await #expect(throws: ChapterWorkerError.invalidManifest) { try await worker.render(readSet, authority: authority) }
        #expect(await f.signals.loads == 0)
        #expect(try f.bundles().isEmpty)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func roleAliasesAndReplacedDirectoriesReject() async throws {
        let f = try LocalWorkerFixture()
        #expect(throws: ChatterboxMacWorkerError.invalidDirectories) {
            try ChatterboxMacWorkerDirectories(sourcePublications: f.directories.sourcePublications, planPublications: f.directories.planPublications,
                state: f.directories.state, exports: f.directories.custody, custody: f.directories.custody, publications: f.directories.publications)
        }
        let (worker, _, outbox, _, _) = try await f.setup()
        let old = f.root.appendingPathComponent("Old-Exports")
        try FileManager.default.moveItem(at: f.directories.exports, to: old)
        try FileManager.default.createDirectory(at: f.directories.exports, withIntermediateDirectories: false)
        await #expect(throws: ChatterboxMacWorkerError.invalidDirectories) { try await worker.enable() }
        #expect(await f.signals.loads == 0)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func budgetedFreshProductionSettlesBeforeReturnAndRecoveryNeedsNoModelReload() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        try await worker.enable()
        let first = try await worker.render(readSet, authority: authority)
        #expect(!first.reusedCompletedAudio)
        let usage = try await budget.inventory()
        #expect(usage.logicalBytes > 0)
        let token = try await budget.reserve(bytes: 1); try await budget.releaseAfterJoining(token)
        try await worker.shutdown(); await outbox.close()
        // New private role owner, same exact complete artifact. The smaller
        // recovery allowance must not require the fresh six-hour envelope.
        let audio = f.directories.publications.appendingPathComponent(first.reference.identifier).appendingPathComponent("audio")
        let bytes = try Data(contentsOf: audio).count
        let recoveryBudget = try f.budget(maximum: usage.logicalBytes + UInt64(bytes * 2 + ChapterLocalHandoff.maximumMetadataBytes + 4096))
        #expect(await recoveryBudget.policy.maximumManagedBytes < ChatterboxMacWorkerStoragePolicy.freshAdmissionBytes)
        let (next, _, currentOutbox, currentSet, currentAuthority) = try await f.setup(artifactBudget: recoveryBudget)
        try await next.enable()
        let cached = try await next.render(currentSet, authority: currentAuthority)
        #expect(cached.reusedCompletedAudio && cached.reference == first.reference)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        #expect(try await currentOutbox.retainedHandoff(for: submission.request) == nil)
        try await next.shutdown(); await currentOutbox.close()
    }
    @Test func insufficientFreshAdmissionFailsBeforePreparationWithoutDeletingAnything() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget(maximum: ChatterboxMacWorkerStoragePolicy.freshAdmissionBytes - 1)
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        let keep = f.directories.exports.appendingPathComponent("unknown"); try Data("keep".utf8).write(to: keep)
        try await worker.enable()
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await worker.render(readSet, authority: authority) }
        let counts = await f.signals.counts(); #expect(counts.0 == 0 && counts.1 == 0)
        #expect(try await worker.checkpoint(for: submission.request)?.failure == .storage)
        #expect(try String(contentsOf: keep, encoding: .utf8) == "keep")
        #expect(try f.bundles().isEmpty)
        try await worker.shutdown(); await outbox.close()
        await #expect(throws: ChapterStorageBudgetError.closed) { try await budget.inventory() }
    }
    @Test func transferredBudgetRejectsExtraReaderOrControlRootsBeforeClaims() async throws {
        let f = try LocalWorkerFixture()
        let budget = try ChapterArtifactStorageBudget(controlDirectory: f.directories.exports,
            managedDirectories: [f.directories.exports, f.directories.custody, f.directories.publications, f.directories.state],
            policy: .init(maximumManagedBytes: ChatterboxMacWorkerStoragePolicy.freshAdmissionBytes, minimumAvailableBytes: 0))
        let (worker, _, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        await #expect(throws: ChapterStorageBudgetError.invalidConfiguration) { try await worker.enable() }
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await worker.render(readSet, authority: authority) }
        #expect(await f.signals.loads == 0)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func readerCancellationDuringStorageAdmissionCannotStartPreparation() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget(), counter = WorkerHookCounter()
        await budget.pauseScanForTesting {
            if await counter.next() == 1 {
                await f.signals.signal("budget-entered"); await f.signals.wait("budget-release")
            }
        }
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        try await worker.enable()
        let render = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("budget-entered")
        _ = try await outbox.setDemand(false, for: submission.request)
        await f.signals.signal("budget-release")
        await #expect(throws: ChapterLocalIntentError.staleIntent) { try await render.value }
        let counts = await f.signals.counts(); #expect(counts.0 == 0 && counts.1 == 0)
        #expect(try await worker.checkpoint(for: submission.request)?.phase == .interrupted)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func disableKeepsAllowanceAndLocksUntilOriginalBudgetedProducerJoins() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, _, outbox, readSet, authority) = try await f.setup(pauseRender: true, artifactBudget: budget)
        try await worker.enable()
        let render = Task { try await worker.render(readSet, authority: authority) }
        await f.signals.wait("render-entered")
        let stop = Task { try await worker.disable() }; stop.cancel()
        await f.signals.wait("render-cancelled")
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        #expect(throws: ChapterStorageBudgetError.alreadyOpen) { try f.budget() }
        await f.signals.signal("render-release")
        try await stop.value
        await #expect(throws: CancellationError.self) { try await render.value }
        let token = try await budget.reserve(bytes: 1); try await budget.releaseAfterJoining(token)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func lateStorageFailureNeverReturnsPhysicalPublicationAsSuccessfulWork() async throws {
        let f = try LocalWorkerFixture(), limit = ChatterboxMacWorkerStoragePolicy.freshAdmissionBytes + 16 * 1024 * 1024
        let budget = try f.budget(maximum: limit)
        let unknown = f.directories.exports.appendingPathComponent("retained-sparse-unknown")
        let hooks = LocalWorkerLifecycleHooks(beforeStorageSettlement: {
            let fd = Darwin.open(unknown.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ChapterWorkerError.invalidManifest }; defer { Darwin.close(fd) }
            guard ftruncate(fd, off_t(limit + 1)) == 0 else { throw ChapterWorkerError.invalidManifest }
        })
        let (worker, submission, outbox, readSet, authority) = try await f.setup(hooks: hooks, artifactBudget: budget)
        try await worker.enable()
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await worker.render(readSet, authority: authority) }
        let checkpoint = try await #require(worker.checkpoint(for: submission.request))
        #expect(checkpoint.phase == .failed && checkpoint.failure == .storage && checkpoint.completedHandoff != nil)
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        #expect(try !f.bundles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        try await worker.shutdown(); await outbox.close()
    }
    @Test func joinedWorkerCompletionIsImmutableIdempotentAndReaderVerifiesAudioSeparately() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        #expect(try await ChapterLocalCompletion.receiveIfPresent(for: readSet, session: submission.session,
            gate: f.readerGate, authority: authority, directory: f.directories.publications) == nil)
        try await worker.enable()
        let result = try await worker.render(readSet, authority: authority)
        let first = try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
            budget: budget, directory: f.directories.publications)
        let second = try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
            budget: budget, directory: f.directories.publications)
        #expect(first.handoffReference == second.handoffReference && first.readSet == readSet)
        let freshReader = try await f.readerGate.open(accountPartition: f.partition)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterLocalCompletion.receiveIfPresent(for: readSet, session: submission.session,
                gate: f.readerGate, authority: authority, directory: f.directories.publications)
        }
        let freshSubmission = try ChapterSubmission(request: submission.request, originalText: submission.originalText, session: freshReader)
        let receipt = try await #require(ChapterLocalCompletion.receiveIfPresent(for: readSet, session: freshReader,
            gate: f.readerGate, authority: authority, directory: f.directories.publications))
        #expect(receipt.handoffReference == result.reference)
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        let received = try await ChapterLocalHandoff.receive(receipt.handoffReference, submission: freshSubmission, gate: f.readerGate,
            directory: f.directories.publications, storageDirectory: f.readerCustody)
        let accepted = try await outbox.acceptVerifiedHandoff(received, submission: freshSubmission, readSet: readSet, gate: f.readerGate)
        #expect(accepted.artifact.decodedFrameCount == result.decodedFrames)
        let key = try ChapterLocalCompletion.lookupKey(for: readSet)
        let bytes = try Data(contentsOf: f.directories.publications.appendingPathComponent("completion-" + key + ".json"))
        let json = String(decoding: bytes, as: UTF8.self)
        #expect(!json.contains(result.producerSession.epoch.uuidString) && !json.contains("completeWarmSeconds"))
        try await worker.shutdown(); await outbox.close()
    }
    @Test func completionLostAcknowledgementPreservesCompleteRecordAndSkipsNoVerification() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        try await worker.enable(); let result = try await worker.render(readSet, authority: authority)
        await #expect(throws: CancellationError.self) {
            try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
                budget: budget, directory: f.directories.publications) { if case .afterCommit = $0 { throw CancellationError() } }
        }
        let record = try await #require(ChapterLocalCompletion.receiveIfPresent(for: readSet, session: submission.session,
            gate: f.readerGate, authority: authority, directory: f.directories.publications))
        #expect(record.handoffReference == result.reference)
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        _ = try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
            budget: budget, directory: f.directories.publications)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        try await worker.shutdown(); await outbox.close()
    }
    @Test func stoppedWorkerPublicationCannotEmitCompletionAfterReenable() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, _, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        try await worker.enable(); let result = try await worker.render(readSet, authority: authority)
        try await worker.disable(); try await worker.enable()
        await #expect(throws: CancellationError.self) {
            try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
                budget: budget, directory: f.directories.publications)
        }
        let key = try ChapterLocalCompletion.lookupKey(for: readSet)
        #expect(!FileManager.default.fileExists(atPath: f.directories.publications.appendingPathComponent("completion-" + key + ".json").path))
        try await worker.shutdown(); await outbox.close()
    }
    @Test func completionPublisherCancellationJoinsBeforeAllowanceAndUnknownFilesRelease() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, _, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        try await worker.enable(); let result = try await worker.render(readSet, authority: authority)
        let keep = f.directories.publications.appendingPathComponent("keep"); try Data("keep".utf8).write(to: keep)
        let publish = Task {
            try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
                budget: budget, directory: f.directories.publications) {
                    if case .beforeCommit = $0 { await f.signals.signal("completion-entered"); await f.signals.wait("completion-release") }
                }
        }
        await f.signals.wait("completion-entered"); publish.cancel()
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        await f.signals.signal("completion-release")
        await #expect(throws: CancellationError.self) { try await publish.value }
        let token = try await budget.reserve(bytes: 1); try await budget.releaseAfterJoining(token)
        #expect(try String(contentsOf: keep, encoding: .utf8) == "keep")
        try await worker.shutdown(); await outbox.close()
    }
    @Test func staleReaderIntentAndRevokedProducerEpochRejectCompletion() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        try await worker.enable(); let result = try await worker.render(readSet, authority: authority)
        await #expect(throws: ChapterLocalIntentError.staleIntent) {
            try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
                budget: budget, directory: f.directories.publications) {
                    if case .beforeCommit = $0 { _ = try await outbox.setDemand(false, for: submission.request) }
                }
        }
        _ = try await f.workerGate.open(accountPartition: f.partition)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
                budget: budget, directory: f.directories.publications)
        }
        try await worker.shutdown(); await outbox.close()
    }
    @Test func conflictingReceiptAndCorruptOrSymlinkRecordsAreNeverReplacedOrAccepted() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        try await worker.enable(); let result = try await worker.render(readSet, authority: authority)
        _ = try await ChatterboxMacLocalCompletionPublisher.publish(result, gate: f.workerGate, authority: authority,
            budget: budget, directory: f.directories.publications)
        let key = try ChapterLocalCompletion.lookupKey(for: readSet)
        let file = f.directories.publications.appendingPathComponent("completion-" + key + ".json")
        let original = try Data(contentsOf: file)
        await #expect(throws: ChapterLocalSourceError.invalidRecord) {
            try await ChapterLocalCompletion.publish(readSet: readSet, handoffReference: .init(identifier: String(repeating: "f", count: 64)),
                session: result.producerSession, gate: f.workerGate, authority: authority, directory: f.directories.publications,
                producerFence: result.producerFence)
        }
        #expect(try Data(contentsOf: file) == original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("corrupt".utf8).write(to: file)
        await #expect(throws: (any Error).self) {
            try await ChapterLocalCompletion.receiveIfPresent(for: readSet, session: submission.session,
                gate: f.readerGate, authority: authority, directory: f.directories.publications)
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.voice)
        await #expect(throws: ChapterLocalSourceError.invalidRecord) {
            try await ChapterLocalCompletion.receiveIfPresent(for: readSet, session: submission.session,
                gate: f.readerGate, authority: authority, directory: f.directories.publications)
        }
        try await worker.shutdown(); await outbox.close()
    }
    @Test func supervisorPublishesOnceAndUnchangedIntentObservesOnlyMetadata() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, _, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications)
        try await supervisor.enable()
        let first = try await supervisor.renderAndPublish(readSet, authority: authority)
        #expect(first.newPublication != nil)
        let generation = try await worker.checkpoint(for: readSet.intent.request)?.generation
        let second = try await supervisor.renderAndPublish(readSet, authority: authority)
        #expect(second.newPublication == nil && second.receipt.handoffReference == first.receipt.handoffReference)
        #expect(try await worker.checkpoint(for: readSet.intent.request)?.generation == generation)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        #expect(try await outbox.retainedHandoff(for: readSet.intent.request) == nil)
        try await supervisor.shutdown(); await outbox.close()
    }
    @Test func supervisorStopJoinsPausedMetadataBeforeWorkerAndBudgetShutdown() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let hooks = LocalWorkerLifecycleHooks(beforeStop: { await f.signals.signal("inner-worker-stop") })
        let (worker, _, outbox, readSet, authority) = try await f.setup(hooks: hooks, artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications, checkpoint: {
                if case .beforeCommit = $0 { await f.signals.signal("metadata-entered"); await f.signals.wait("metadata-release") }
            })
        try await supervisor.enable()
        let render = Task { try await supervisor.renderAndPublish(readSet, authority: authority) }
        await f.signals.wait("metadata-entered")
        supervisor.stopClaims() // Direct same-turn admission/cancellation fence.
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await supervisor.renderAndPublish(readSet, authority: authority) }
        let stop = Task { await f.signals.signal("outer-stop-entered"); try await supervisor.shutdown(); await f.signals.signal("outer-stopped") }
        await f.signals.wait("outer-stop-entered")
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        let innerStop = await f.signals.has("inner-worker-stop"), outerStopped = await f.signals.has("outer-stopped")
        #expect(!innerStop && !outerStopped)
        await f.signals.signal("metadata-release")
        await #expect(throws: CancellationError.self) { try await render.value }
        try await stop.value
        #expect(await worker.state() == .closed)
        await outbox.close()
    }
    @Test func supervisorLostReceiptCallbackReconcilesWithoutNewInference() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget(), counter = WorkerHookCounter()
        let (worker, _, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications, checkpoint: {
                if case .afterCommit = $0, await counter.next() == 1 { throw CancellationError() }
            })
        try await supervisor.enable()
        await #expect(throws: CancellationError.self) { try await supervisor.renderAndPublish(readSet, authority: authority) }
        let recovered = try await supervisor.renderAndPublish(readSet, authority: authority)
        #expect(recovered.newPublication == nil)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        try await supervisor.shutdown(); await outbox.close()
    }
    @Test func supervisorMetadataWithoutPrivateWorkerCheckpointCannotAuthorizeRender() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, _, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        _ = try await ChapterLocalCompletion.publish(readSet: readSet,
            handoffReference: .init(identifier: String(repeating: "f", count: 64)), session: session,
            gate: f.workerGate, authority: authority, directory: f.directories.publications, producerFence: {})
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications)
        try await supervisor.enable()
        await #expect(throws: ChapterLocalCompletionError.invalidRecord) { try await supervisor.renderAndPublish(readSet, authority: authority) }
        let counts = await f.signals.counts(); #expect(counts.0 == 0 && counts.1 == 0)
        try await supervisor.shutdown(); await outbox.close()
    }
    @Test func supervisorChangedIntentReverifiesCompletedAudioWithoutFreshModelWork() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications)
        try await supervisor.enable()
        _ = try await supervisor.renderAndPublish(readSet, authority: authority)
        _ = try await outbox.setDemand(false, for: submission.request)
        await #expect(throws: ChapterLocalIntentError.staleIntent) { try await supervisor.renderAndPublish(readSet, authority: authority) }
        _ = try await outbox.setDemand(true, for: submission.request)
        let newReadSet = try await #require(outbox.wantedReadSet(for: submission.request))
        let result = try await supervisor.renderAndPublish(newReadSet, authority: authority)
        #expect(result.newPublication?.reusedCompletedAudio == true && result.receipt.readSet == newReadSet)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        try await supervisor.shutdown(); await outbox.close()
    }
    @Test func supervisorStopDuringOwnedEnableCannotLeaveClaimsEnabled() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let hooks = LocalWorkerLifecycleHooks(beforeEnableCommit: { await f.signals.signal("enable-entered"); await f.signals.wait("enable-release") })
        let (worker, _, outbox, readSet, authority) = try await f.setup(hooks: hooks, artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications)
        let enable = Task { try await supervisor.enable() }
        await f.signals.wait("enable-entered"); supervisor.stopClaims()
        let stop = Task { try await supervisor.disable() }
        await f.signals.signal("enable-release")
        await #expect(throws: CancellationError.self) { try await enable.value }
        try await stop.value
        await #expect(throws: ChatterboxMacWorkerError.disabled) { try await supervisor.renderAndPublish(readSet, authority: authority) }
        try await supervisor.shutdown(); await outbox.close()
    }
    @Test(arguments: [false, true]) func supervisorRefreshesAuthorityAfterProducerBeforeAcceptance(revokeEpoch: Bool) async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications, beforeAcceptance: {
                await f.signals.signal("acceptance-entered"); await f.signals.wait("acceptance-release")
            })
        try await supervisor.enable()
        let render = Task { try await supervisor.renderAndPublish(readSet, authority: authority) }
        await f.signals.wait("acceptance-entered")
        await #expect(throws: ChatterboxMacWorkerError.busy) { try await supervisor.renderAndPublish(readSet, authority: authority) }
        if revokeEpoch { _ = try await f.workerGate.open(accountPartition: f.partition) }
        else { _ = try await outbox.setDemand(false, for: submission.request) }
        await f.signals.signal("acceptance-release")
        if revokeEpoch { await #expect(throws: ChapterWorkerError.accountMismatch) { try await render.value } }
        else { await #expect(throws: ChapterLocalIntentError.staleIntent) { try await render.value } }
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        try await supervisor.shutdown(); await outbox.close()
    }
    @Test func supervisorStopAlsoJoinsPostProducerAcceptanceTask() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let hooks = LocalWorkerLifecycleHooks(beforeStop: { await f.signals.signal("acceptance-inner-stop") })
        let (worker, _, outbox, readSet, authority) = try await f.setup(hooks: hooks, artifactBudget: budget)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications, beforeAcceptance: {
                await f.signals.signal("acceptance-entered"); await f.signals.wait("acceptance-release")
            })
        try await supervisor.enable()
        let render = Task { try await supervisor.renderAndPublish(readSet, authority: authority) }
        await f.signals.wait("acceptance-entered"); supervisor.stopClaims()
        let stop = Task { await f.signals.signal("acceptance-stop-entered"); try await supervisor.shutdown(); await f.signals.signal("acceptance-stopped") }
        await f.signals.wait("acceptance-stop-entered")
        let innerStopped = await f.signals.has("acceptance-inner-stop"), stopped = await f.signals.has("acceptance-stopped")
        #expect(!innerStopped && !stopped)
        await f.signals.signal("acceptance-release")
        await #expect(throws: CancellationError.self) { try await render.value }
        try await stop.value
        #expect(await worker.state() == .closed)
        await outbox.close()
    }
    @Test func concretePreparedServiceDrivesRealLocalWorkerAndVerifiedReaderPlaybackCustody() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, _, authority) = try await f.setup(artifactBudget: budget)
        let service = try f.readerService(submission, outbox: outbox)
        let prepared = try await #require(service.preparedSubmission(for: submission.request, session: submission.session))
        let catalog = try await service.catalog(session: submission.session)
        #expect(catalog.voices.count == 1 && catalog.voices[0].descriptor.id == "librox-narrator")
        #expect(catalog.deliveryDomain == .local)
        let receipt = try await service.submit(prepared)
        #expect(receipt.wanted && receipt.delivery == .localIntent)
        let session = try #require(await f.signals.workerSession)
        let supervisor = ChatterboxMacLocalWorkerSupervisor(worker: worker, session: session, gate: f.workerGate,
            budget: budget, directory: f.directories.publications)
        try await supervisor.enable()
        let readSet = try await #require(outbox.wantedReadSet(for: submission.request))
        _ = try await supervisor.renderAndPublish(readSet, authority: authority)
        let updates = try await service.updates(for: submission.request, session: submission.session)
        var iterator = updates.makeAsyncIterator()
        let remote = try await #require(iterator.next())
        if case .remoteReady = remote.state {} else { Issue.record("Expected complete metadata, never playable before download") }
        let retained = try await outbox.retainedHandoff(for: submission.request)
        #expect(remote.demandReceipt == receipt && retained == nil)
        let artifact = try await service.download(prepared)
        #expect(artifact.decodedFrameCount > 0 && artifact.session == submission.session)
        let playable = try await #require(iterator.next())
        if case .playable(let actual) = playable.state { #expect(actual.decodedFrameCount == artifact.decodedFrameCount) }
        else { Issue.record("Expected actual decoded adopted custody") }
        #expect(playable.demandReceipt == receipt && playable.sequence > remote.sequence)
        try await supervisor.shutdown(); try await service.close(session: submission.session)
        while let _ = try await iterator.next() {}
    }
    @Test func preparedServiceRejectsMismatchedPairAndUnavailableCatalogWithoutWrites() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, _, _) = try await f.setup()
        let service = try f.readerService(submission, outbox: outbox)
        let original = try await #require(service.preparedSubmission(for: submission.request, session: submission.session))
        let options = try ChatterboxChapterRenderOptions(text: f.text, language: "en", seed: 12)
        let forged = ChatterboxPreparedChapterSubmission(submission: submission, plan: try .init(request: options))
        let before = try await outbox.currentIntent(for: submission.request)
        await #expect(throws: ChapterWorkerError.invalidManifest) { try await service.submit(forged) }
        await #expect(throws: ChapterWorkerError.invalidManifest) { try await service.download(forged) }
        #expect(try await outbox.currentIntent(for: submission.request) == before)
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        let restored = try await #require(service.preparedSubmission(for: submission.request, session: submission.session))
        #expect(restored.plan.encoded() == original.plan.encoded())
        try await worker.shutdown(); try await service.close(session: submission.session)
    }
    @Test func preparedServiceCancellationSurvivesStorageCapacityAndRetainsExactPair() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, _, _) = try await f.setup()
        let service = try f.readerService(submission, outbox: outbox, maximumPublicationBytes: 1024 * 1024)
        let prepared = try await #require(service.preparedSubmission(for: submission.request, session: submission.session))
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await service.submit(prepared) }
        let receipt = try await service.cancel(request: submission.request, session: submission.session)
        #expect(!receipt.wanted && receipt.delivery == .localIntent)
        let updates = try await service.updates(for: submission.request, session: submission.session)
        var iterator = updates.makeAsyncIterator()
        let current = try await #require(iterator.next())
        if case .cancelled = current.state {} else { Issue.record("Expected local cancellation") }
        #expect(current.demandReceipt == receipt)
        #expect(try await service.preparedSubmission(for: submission.request, session: submission.session)?.plan.encoded() == prepared.plan.encoded())
        #expect(try await outbox.wantedReadSet(for: submission.request) == nil)
        try await worker.shutdown(); try await service.close(session: submission.session)
    }
    @Test func preparedServiceLateCatalogSubmitCannotResurrectCancelledIntent() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, _, _) = try await f.setup()
        let service = try f.readerService(submission, outbox: outbox, beforeCatalog: {
            await f.signals.signal("service-catalog-entered"); await f.signals.wait("service-catalog-release")
        })
        let prepared = try await #require(service.preparedSubmission(for: submission.request, session: submission.session))
        let submit = Task { try await service.submit(prepared) }
        await f.signals.wait("service-catalog-entered")
        let cancelled = try await service.cancel(request: submission.request, session: submission.session)
        await f.signals.signal("service-catalog-release")
        await #expect(throws: ChatterboxLocalPreparedServiceError.staleCommand) { try await submit.value }
        #expect(try await outbox.currentIntent(for: submission.request)?.revision == cancelled.intentRevision)
        #expect(try await outbox.wantedReadSet(for: submission.request) == nil)
        try await worker.shutdown(); try await service.close(session: submission.session)
    }
    @Test func preparedServiceCloseJoinsCatalogAndDoesNotRevokeNewAccountEpochOrWorker() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, _, _) = try await f.setup()
        let service = try f.readerService(submission, outbox: outbox, beforeCatalog: {
            await f.signals.signal("service-close-entered"); await f.signals.wait("service-close-release")
        })
        let catalog = Task { try await service.catalog(session: submission.session) }
        await f.signals.wait("service-close-entered")
        let close = Task { await f.signals.signal("service-close-requested"); try await service.close(session: submission.session); await f.signals.signal("service-closed") }
        await f.signals.wait("service-close-requested")
        let own = try await f.readerGate.open(accountPartition: f.partition)
        #expect(!(await f.signals.has("service-closed")))
        await f.signals.signal("service-close-release")
        await #expect(throws: (any Error).self) { try await catalog.value }
        try await close.value
        try await f.readerGate.validate(own)
        #expect(await worker.state() == .disabled)
        await #expect(throws: ChapterOutboxError.closed) { try await outbox.currentIntent(for: submission.request) }
        try await worker.shutdown()
    }
    @Test func preparedServiceUnavailableStockDoesNotAcceptNewDemand() async throws {
        let f = try LocalWorkerFixture(), (worker, submission, outbox, _, _) = try await f.setup()
        let service = try f.readerService(submission, outbox: outbox, available: false)
        let prepared = try await #require(service.preparedSubmission(for: submission.request, session: submission.session))
        let before = try await outbox.currentIntent(for: submission.request)
        await #expect(throws: ChatterboxLocalPreparedServiceError.notReady) { try await service.submit(prepared) }
        #expect(try await outbox.currentIntent(for: submission.request) == before)
        try await worker.shutdown(); try await service.close(session: submission.session)
    }
    @Test func nativeHostPendingApprovalPreparesButCannotClaimAlreadyWantedChapter() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, _, authority) = try await f.setup(artifactBudget: budget)
        let session = try #require(await f.signals.workerSession), renderer = try #require(await f.signals.renderer)
        let host = ChatterboxMacLocalWorkerHost(renderer: renderer, worker: worker, budget: budget,
            session: session, gate: f.workerGate, directories: f.directories, authority: authority)
        try await host.start()
        let catalog = try await host.catalog(for: submission.session, gate: f.readerGate)
        #expect(catalog.voices[0].availability == .unavailable && catalog.voices[0].listeningApproval == .pending)
        let snapshot = try await host.snapshot()
        #expect(snapshot.state == .prepared && snapshot.workerPhase == .disabled)
        #expect(try await worker.checkpoint(for: submission.request) == nil)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 0)
        try await host.shutdown(); await outbox.close()
    }
    @Test func nativeHostApprovedDriverCompletesQueuedChapterAndReaderFactoryAdoptsIt() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, readSet, authority) = try await f.setup(artifactBudget: budget)
        await outbox.close()
        let session = try #require(await f.signals.workerSession), renderer = try #require(await f.signals.renderer)
        let host = ChatterboxMacLocalWorkerHost(renderer: renderer, worker: worker, budget: budget,
            session: session, gate: f.workerGate, directories: f.directories, authority: authority, approval: .approved)
        let directories = try ChatterboxLocalReaderDirectories(sources: f.directories.sourcePublications, plans: f.directories.planPublications,
            outbox: f.readerOutbox, authority: f.readerAuthority, artifacts: f.readerCustody, publications: f.directories.publications)
        let service = try await ChatterboxLocalPreparedChapterService.open(session: submission.session, gate: f.readerGate,
            deviceID: f.device, directories: directories,
            publicationPolicy: .init(maximumManagedBytes: 16 * 1024 * 1024, minimumAvailableBytes: 0),
            artifactPolicy: .init(maximumManagedBytes: 16 * 1024 * 1024, minimumAvailableBytes: 0)) { own in
                try await host.catalog(for: own, gate: f.readerGate)
            }
        await #expect(throws: ChatterboxLocalPreparedServiceError.notReady) { try await service.catalog(session: submission.session) }
        try await host.start()
        let key = try ChapterLocalCompletion.lookupKey(for: readSet)
        let receipt = f.directories.publications.appendingPathComponent("completion-" + key + ".json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: receipt.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        let prepared = try await #require(service.preparedSubmission(for: submission.request, session: submission.session))
        let actual = try await service.download(prepared)
        #expect(actual.decodedFrameCount > 0)
        let firstGeneration = try await worker.checkpoint(for: submission.request)?.generation
        // Driver keeps the same wanted identity handled; a metadata observation
        // and repeated download must not create a second generation/inference.
        _ = try await service.download(prepared)
        #expect(try await worker.checkpoint(for: submission.request)?.generation == firstGeneration)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        host.stopClaims(); try await host.shutdown(); try await service.close(session: submission.session)
    }
    @Test func nativeHostStopDuringPreparationJoinsAndEnablesNoClaims() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, _, authority) = try await f.setup(pauseLoad: true, artifactBudget: budget)
        let session = try #require(await f.signals.workerSession), renderer = try #require(await f.signals.renderer)
        let host = ChatterboxMacLocalWorkerHost(renderer: renderer, worker: worker, budget: budget,
            session: session, gate: f.workerGate, directories: f.directories, authority: authority, approval: .approved)
        let start = Task { try await host.start() }
        await f.signals.wait("load-entered"); host.stopClaims()
        await f.signals.wait("load-cancelled")
        let stop = Task { try await host.shutdown() }
        await f.signals.signal("load-release")
        await #expect(throws: (any Error).self) { try await start.value }
        try await stop.value
        let counts = await f.signals.counts(); #expect(counts.1 == 0)
        await outbox.close()
    }
    @Test func publicColdWorkerFactoryDoesNotLoadModelsAndClosesPrivateRole() async throws {
        let f = try LocalWorkerFixture()
        let reader = try await f.readerGate.open(accountPartition: f.partition), own = try await f.workerGate.open(accountPartition: f.partition)
        let outbox = try await ChapterDemandOutbox.openWithDurableAuthority(directory: f.readerOutbox,
            authorityDirectory: f.readerAuthority, accountPartition: f.partition, deviceID: f.device)
        let authority = ChapterDurableIntentAuthority(directory: f.readerAuthority, descriptor: try await outbox.durableIntentDescriptor())
        let missing = f.root.appendingPathComponent("not-a-model")
        let assets = ChatterboxMacModelAssets(metallib: missing, acousticCheckpoint: missing, decoderWeights: missing,
            decoderOracle: missing, frontendDirectory: missing, stockConditioning: missing)
        let host = try await ChatterboxMacLocalWorkerHost.open(assets: assets, workerID: f.workerID, session: own,
            gate: f.workerGate, directories: f.directories, authority: authority,
            storagePolicy: .init(maximumManagedBytes: ChatterboxMacWorkerStoragePolicy.freshAdmissionBytes, minimumAvailableBytes: 0))
        let snapshot = try await host.snapshot()
        #expect(snapshot.state == .disabled && snapshot.workerPhase == .disabled)
        await #expect(throws: ChatterboxLocalPreparedServiceError.notReady) { try await host.catalog(for: reader, gate: f.readerGate) }
        try await host.shutdown(); await outbox.close()
    }
    @Test(arguments: [false, true]) func localPairRejectsCrossOwnerControlAndArtifactAliases(ancestor: Bool) async throws {
        let f = try LocalWorkerFixture()
        let reader = try await f.readerGate.open(accountPartition: f.partition), own = try await f.workerGate.open(accountPartition: f.partition)
        let exportRoot: URL, authorityRoot: URL
        if ancestor {
            exportRoot = f.root.appendingPathComponent("Nested-Worker-Exports")
            authorityRoot = exportRoot.appendingPathComponent("Reader-Authority")
            try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: authorityRoot, withIntermediateDirectories: false)
        } else { exportRoot = f.readerAuthority; authorityRoot = f.readerAuthority }
        let readers = try ChatterboxLocalReaderDirectories(sources: f.directories.sourcePublications, plans: f.directories.planPublications,
            outbox: f.readerOutbox, authority: authorityRoot, artifacts: f.readerCustody, publications: f.directories.publications)
        let workers = try ChatterboxMacWorkerDirectories(sourcePublications: f.directories.sourcePublications,
            planPublications: f.directories.planPublications, state: f.directories.state, exports: exportRoot,
            custody: f.directories.custody, publications: f.directories.publications)
        let missing = f.root.appendingPathComponent("not-a-model")
        let assets = ChatterboxMacModelAssets(metallib: missing, acousticCheckpoint: missing, decoderWeights: missing,
            decoderOracle: missing, frontendDirectory: missing, stockConditioning: missing)
        let policy = try ChapterStorageBudgetPolicy(maximumManagedBytes: 16 * 1024 * 1024, minimumAvailableBytes: 0)
        await #expect(throws: ChatterboxMacWorkerError.invalidDirectories) {
            try await ChatterboxMacLocalServicePair.open(assets: assets, readerSession: reader, readerGate: f.readerGate,
                deviceID: f.device, workerSession: own, workerGate: f.workerGate, workerID: f.workerID,
                readerDirectories: readers, workerDirectories: workers,
                publicationPolicy: policy, artifactPolicy: policy, workerPolicy: policy)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.readerOutbox.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: authorityRoot.path).isEmpty)
    }
    @Test func nativeHostStorageShutdownStopsDriverAndCannotAdvertiseAvailable() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let hooks = LocalWorkerLifecycleHooks(beforeStorageSettlement: { throw ChapterStorageBudgetError.capacity })
        let (worker, submission, outbox, readSet, authority) = try await f.setup(hooks: hooks, artifactBudget: budget)
        let session = try #require(await f.signals.workerSession), renderer = try #require(await f.signals.renderer)
        let host = ChatterboxMacLocalWorkerHost(renderer: renderer, worker: worker, budget: budget,
            session: session, gate: f.workerGate, directories: f.directories, authority: authority, approval: .approved)
        try await host.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var snapshot = try await host.snapshot()
        while snapshot.state != .disabled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)); snapshot = try await host.snapshot()
        }
        #expect(snapshot.state == .disabled && snapshot.lastFailure?.code == .storage)
        let catalog = try await host.catalog(for: submission.session, gate: f.readerGate)
        #expect(catalog.voices[0].availability == .unavailable)
        let key = try ChapterLocalCompletion.lookupKey(for: readSet)
        #expect(!FileManager.default.fileExists(atPath: f.directories.publications.appendingPathComponent("completion-" + key + ".json").path))
        #expect(try await outbox.retainedHandoff(for: submission.request) == nil)
        let checkpoint = try await #require(worker.checkpoint(for: submission.request))
        #expect(checkpoint.phase == .failed && checkpoint.failure == .storage && checkpoint.completedHandoff != nil)
        try await host.shutdown(); await outbox.close()
    }
    @Test func nativeHostHealthyBusyCatalogCanQueueWithoutConcurrentClaims() async throws {
        let f = try LocalWorkerFixture(), budget = try f.budget()
        let (worker, submission, outbox, _, authority) = try await f.setup(pauseRender: true, artifactBudget: budget)
        let session = try #require(await f.signals.workerSession), renderer = try #require(await f.signals.renderer)
        let host = ChatterboxMacLocalWorkerHost(renderer: renderer, worker: worker, budget: budget,
            session: session, gate: f.workerGate, directories: f.directories, authority: authority, approval: .approved)
        try await host.start(); await f.signals.wait("render-entered")
        let catalog = try await host.catalog(for: submission.session, gate: f.readerGate)
        #expect(catalog.voices[0].availability == .available)
        let snapshot = try await host.snapshot()
        #expect(snapshot.workerPhase == .rendering && snapshot.activeRequest == submission.request)
        let existing = try await #require(outbox.storedSubmission(for: submission.request))
        let current = try await ChatterboxLocalRenderPlan.receive(try #require(existing.renderPlanReference), submission: submission,
            gate: f.readerGate, directory: f.directories.planPublications)
        let options = try current.restore(source: f.text)
        let source = try ChapterSourceIdentity(bookSHA256: submission.request.source.bookSHA256, chapterKey: "chapter:2",
            textSHA256: submission.request.source.textSHA256, extractionRevision: submission.request.source.extractionRevision,
            utf16Length: f.text.utf16.count)
        let prepared = try catalog.voices[0].descriptor.prepareChapter(source: source, options: options, session: submission.session)
        let publicationBudget = try ChapterArtifactStorageBudget(controlDirectory: f.directories.sourcePublications,
            managedDirectories: [f.directories.sourcePublications, f.directories.planPublications],
            policy: .init(maximumManagedBytes: 16 * 1024 * 1024, minimumAvailableBytes: 0))
        _ = try await ChatterboxLocalSubmissionAdmission.submit(prepared.plan, submission: prepared.submission,
            gate: f.readerGate, outbox: outbox, budget: publicationBudget,
            sourceDirectory: f.directories.sourcePublications, planDirectory: f.directories.planPublications)
        let counts = await f.signals.counts(); #expect(counts.0 == 1 && counts.1 == 1)
        await f.signals.signal("render-release")
        let readSet = try await #require(outbox.wantedReadSet(for: prepared.submission.request))
        let key = try ChapterLocalCompletion.lookupKey(for: readSet)
        let receipt = f.directories.publications.appendingPathComponent("completion-" + key + ".json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: receipt.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: receipt.path))
        let final = await f.signals.counts(); #expect(final.0 == 1 && final.1 == 2)
        try await host.shutdown(); try await publicationBudget.close(); await outbox.close()
    }
}
#endif
