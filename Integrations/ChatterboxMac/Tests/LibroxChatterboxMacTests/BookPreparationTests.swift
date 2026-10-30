#if os(macOS)
import Foundation
import Testing
import LibroxChapterWorker
import LibroxChatterbox
@testable import LibroxChatterboxPlanning

private actor BookAdmissionGate {
    private var signals: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    func signal(_ name: String) { signals.insert(name); for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.resume() } }
    func wait(_ name: String) async { if !signals.contains(name) { await withCheckedContinuation { waiters[name, default: []].append($0) } } }
    func has(_ name: String) -> Bool { signals.contains(name) }
}
private final class PreparedBookFixture: Sendable {
    let root, sources, plans, control: URL
    let gate = ChapterAccountSessionGate()
    let deviceID = UUID()
    let partition = String(repeating: "a", count: 64)
    let text = "Cafe\u{301} 🐈.\r\n¡Sigue adelante!"
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sources = root.appendingPathComponent("Sources"); plans = root.appendingPathComponent("Plans"); control = root.appendingPathComponent("Books")
        for url in [sources, plans, control] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func descriptor(model: String = "b") throws -> ChatterboxStockVoiceDescriptor {
        try .init(modelSHA256: String(repeating: model, count: 64), conditioningSHA256: String(repeating: "c", count: 64), rendererProfile: "synthetic-book-policy-no-inference")
    }
    func book(_ session: ChapterAccountSession, model: String = "b") throws -> ChatterboxPreparedBookSubmission {
        try descriptor(model: model).prepareBook(source: .init(bookSHA256: String(repeating: "d", count: 64),
            extractionRevision: "reader-1", chapterKeys: ["spine:0", "spine:1", "spine:2"]), settings: .init(
                language: "es", delivery: .smaller, direction: .storyteller, grouping: .compatibleNarration(maxCharacters: 160), seed: .max), session: session)
    }
    func directions() throws -> ChatterboxPerformanceDirections {
        let range = (text as NSString).range(of: "Cafe\u{301} 🐈.")
        return try .init(source: text, annotations: [
            .init(range: range, originalText: (text as NSString).substring(with: range),
                performance: .init(delivery: .soft, strength: .subtle), controls: .init(
                    exaggeration: Float(bitPattern: 0x80000000), guidance: Float(bitPattern: 0x3e99999a), temperature: Float(bitPattern: 0x3f4ccccd)))
        ], scope: .chapterV1)
    }
    func pair(_ book: ChatterboxPreparedBookSubmission, _ session: ChapterAccountSession) throws -> ChatterboxPreparedChapterSubmission {
        guard case .chapter(let prepared) = try book.prepareEntry(chapterIndex: 2, text: text,
            performanceDirections: directions(), session: session) else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        return prepared
    }
    func budget(maximum: UInt64 = 32 * 1024 * 1024) throws -> ChapterArtifactStorageBudget {
        try .init(controlDirectory: sources, managedDirectories: [sources, plans], policy: .init(maximumManagedBytes: maximum, minimumAvailableBytes: 0))
    }
    func outbox() throws -> ChapterBookOutbox { try .init(directory: control, accountPartition: partition, deviceID: deviceID) }
}

@Suite(.serialized) struct BookPreparationTests {
    @Test func actualPolicyRestoresSeedAndAuthoredFloatBitsWithoutModelOrDefaultHashes() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), restored = try ChatterboxPreparedBookSubmission.restore(scope: book.scope, session: session)
        #expect(restored.settings.seed == .max); #expect(restored.settings.delivery == .smaller)
        let pair = try f.pair(restored, session), options = try pair.plan.restore(source: f.text)
        let controls = try #require(options.performanceDirections?.annotations.first?.controls)
        #expect(controls.exaggeration.bitPattern == 0x80000000); #expect(controls.temperature.bitPattern == 0x3f4ccccd)
        #expect(options.seed == .max); #expect(options.grouping == .compatibleNarration(maxCharacters: 160))
        try restored.validate(pair, chapterIndex: 2)
        guard case .silent(let cover) = try restored.prepareEntry(chapterIndex: 0, text: "\u{FFFC}\n", session: session) else {
            Issue.record("Cover wasn't explicitly accounted"); return
        }
        #expect(cover.chapterIndex == 0)
        guard case .chapter = try restored.prepareEntry(chapterIndex: 1, text: "Copyright 1900.", session: session) else {
            Issue.record("Meaningful front matter dropped"); return
        }
        #expect(try f.book(session, model: "e").scope.identifier != book.scope.identifier)
    }
    @Test func exactLazySourcePlanAndBookIntentRecoverUnderFreshReceiverEpoch() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), pair = try f.pair(book, session), outbox = try f.outbox(), budget = try f.budget()
        _ = try await outbox.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 2, sourceUTF16Offset: 0))
        let intent = try await ChatterboxBookSubmissionAdmission.submit(pair, book: book, chapterIndex: 2,
            gate: f.gate, outbox: outbox, budget: budget, sourceDirectory: f.sources, planDirectory: f.plans)
        #expect(intent.wanted); #expect(intent.wantedRevision == 1)
        await outbox.close()
        let fresh = try await f.gate.open(accountPartition: f.partition), reopened = try f.outbox()
        let stored = try #require(await reopened.stored(scopeID: book.scope.identifier)), entry = try #require(stored.chapters.first)
        let restored = try ChatterboxPreparedBookSubmission.restore(scope: stored.scope, session: fresh)
        let submission = try await ChapterLocalSource.receive(#require(entry.sourceReference), request: #require(entry.request),
            session: fresh, gate: f.gate, directory: f.sources)
        let plan = try await ChatterboxLocalRenderPlan.receive(#require(entry.renderPlanReference), submission: submission, gate: f.gate, directory: f.plans)
        #expect(plan.encoded() == pair.plan.encoded()); #expect(submission.originalText == f.text)
        try restored.validate(.init(submission: submission, plan: plan), chapterIndex: 2)
        let bytes = try Data(contentsOf: f.control.appendingPathComponent(f.partition).appendingPathComponent(f.deviceID.uuidString.lowercased()).appendingPathComponent("journal.json"))
        #expect(bytes.range(of: Data(f.text.utf8)) == nil); #expect(bytes.range(of: Data(session.epoch.uuidString.utf8)) == nil)
        await reopened.close(); try await budget.close()
    }
    @Test func wrongBookPolicyRejectsBeforeWritingOrMakingChapterWanted() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), other = try f.book(session, model: "e"), outbox = try f.outbox(), budget = try f.budget()
        _ = try await outbox.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 2, sourceUTF16Offset: 0))
        await #expect(throws: ChatterboxChapterRenderPlanError.recipeMismatch) {
            try await ChatterboxBookSubmissionAdmission.submit(f.pair(other, session), book: book, chapterIndex: 2,
                gate: f.gate, outbox: outbox, budget: budget, sourceDirectory: f.sources, planDirectory: f.plans)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.sources.path) == ["artifact-budget.lock"])
        #expect(try await outbox.stored(scopeID: book.scope.identifier)?.chapters.isEmpty == true)
        await outbox.close(); try await budget.close()
    }
    @Test func lateCancelRerequestRejectsJoinedPublicationWithoutRemovingCompletedSource() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), pair = try f.pair(book, session), outbox = try f.outbox(), budget = try f.budget(), signal = BookAdmissionGate()
        let priority = try ChapterBookPriority(chapterIndex: 2, sourceUTF16Offset: 0)
        _ = try await outbox.setWanted(true, scope: book.scope, priority: priority)
        let task = Task {
            try await ChatterboxBookSubmissionAdmission.submit(pair, book: book, chapterIndex: 2, gate: f.gate,
                outbox: outbox, budget: budget, sourceDirectory: f.sources, planDirectory: f.plans) { event in
                    if case .beforeIntent = event { await signal.signal("ready"); await signal.wait("release") }
                }
        }
        await signal.wait("ready")
        _ = try await outbox.setWanted(false, scope: book.scope, priority: priority)
        _ = try await outbox.setWanted(true, scope: book.scope, priority: priority)
        await signal.signal("release")
        await #expect(throws: ChapterBookJournalError.staleAdmission) { try await task.value }
        #expect(try await outbox.stored(scopeID: book.scope.identifier)?.chapters.isEmpty == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.sources.path).contains { $0.hasSuffix(".json") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.plans.path).contains { $0.hasSuffix(".json") })
        await outbox.close(); try await budget.close()
    }
    @Test func cancellationJoinsOriginalPublicationBeforeReleasingAllowance() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), pair = try f.pair(book, session), outbox = try f.outbox(), budget = try f.budget(), signal = BookAdmissionGate()
        _ = try await outbox.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 2, sourceUTF16Offset: 0))
        let task = Task {
            do {
                let result = try await ChatterboxBookSubmissionAdmission.submit(pair, book: book, chapterIndex: 2, gate: f.gate,
                    outbox: outbox, budget: budget, sourceDirectory: f.sources, planDirectory: f.plans) { event in
                        if case .afterSource = event {
                            await signal.signal("source")
                            await withTaskCancellationHandler { await signal.wait("release") } onCancel: { Task { await signal.signal("cancelled") } }
                            try Task.checkCancellation()
                        }
                    }
                await signal.signal("returned"); return result
            } catch { await signal.signal("returned"); throw error }
        }
        await signal.wait("source"); task.cancel()
        await signal.wait("cancelled")
        #expect(await !signal.has("returned"))
        await signal.signal("release")
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await outbox.stored(scopeID: book.scope.identifier)?.chapters.isEmpty == true)
        await outbox.close(); try await budget.close()
    }
    @Test func ordinaryArtifactCapacityNeverBlocksBookCancellationControl() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), pair = try f.pair(book, session), outbox = try f.outbox(), budget = try f.budget(maximum: 1024)
        let priority = try ChapterBookPriority(chapterIndex: 2, sourceUTF16Offset: 0)
        _ = try await outbox.setWanted(true, scope: book.scope, priority: priority)
        await #expect(throws: ChapterStorageBudgetError.capacity) {
            try await ChatterboxBookSubmissionAdmission.submit(pair, book: book, chapterIndex: 2, gate: f.gate,
                outbox: outbox, budget: budget, sourceDirectory: f.sources, planDirectory: f.plans)
        }
        let cancel = try await outbox.setWanted(false, scope: book.scope, priority: priority)
        #expect(!cancel.wanted); #expect(try await outbox.pending().count == 1)
        await outbox.close(); try await budget.close()
    }
    @Test func resolvedSeekMetadataRequiresTargetPrefixAndActualRenderedUnitBoundary() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), pair = try f.pair(book, session), outbox = try f.outbox()
        let intent = try await outbox.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 2, sourceUTF16Offset: 0))
        let firstRange = (f.text as NSString).range(of: "Cafe\u{301} 🐈."), secondRange = (f.text as NSString).range(of: "¡Sigue adelante!")
        func manifest(index: Int, previous: String?, start: Int, end: Int, unit: NSRange, frame: Int64) throws -> ChapterSegmentManifest {
            let span = ChapterTextRange(offset: unit.location, length: unit.length)
            let audio = ChapterArtifactManifest(renderKey: try pair.submission.request.renderKey(), audioSHA256: String(repeating: "1", count: 64),
                audioByteCount: 256, decodedFrameCount: 100, codecRevision: pair.submission.request.effectiveDelivery.codecRevision,
                units: [.init(source: span, fragments: [span], startFrame: 0, frameCount: 100)])
            return try .init(request: pair.submission.request, segmentIndex: index, previousSegmentSHA256: previous,
                sourceRange: .init(offset: start, length: end - start), chapterStartFrame: frame, audio: audio, originalText: f.text)
        }
        let first = try manifest(index: 0, previous: nil, start: 0, end: NSMaxRange(firstRange), unit: firstRange, frame: 0)
        let second = try manifest(index: 1, previous: first.sha256(), start: NSMaxRange(firstRange), end: f.text.utf16.count, unit: secondRange, frame: 100)
        var prefix = try ChapterSegmentPrefix(request: pair.submission.request, originalText: f.text)
        try prefix.append(first)
        let target = try ChatterboxResolvedBookSegment(book: book, intent: intent, chapterIndex: 2, prepared: pair, manifest: first, prefix: prefix, localStartFrame: 0)
        #expect(target.prefix.segmentCount == 1); #expect(target.localStartFrame == 0)
        #expect(throws: ChapterWorkerError.invalidManifest) {
            try ChatterboxResolvedBookSegment(book: book, intent: intent, chapterIndex: 2, prepared: pair, manifest: first, prefix: prefix, localStartFrame: 1)
        }
        try prefix.append(second)
        #expect(throws: ChapterWorkerError.invalidManifest) {
            try ChatterboxResolvedBookSegment(book: book, intent: intent, chapterIndex: 2, prepared: pair, manifest: first, prefix: prefix, localStartFrame: 0)
        }
        let next = try ChatterboxResolvedBookSegment(book: book, intent: intent, chapterIndex: 2, prepared: pair, manifest: second, prefix: prefix, localStartFrame: 0)
        #expect(next.prefix.segmentCount == 2)
        let seal = try prefix.completionSeal()
        let completion = try ChatterboxResolvedBookChapterCompletion(book: book, intent: intent, chapterIndex: 2,
            prepared: pair, seal: seal, finalPrefix: prefix)
        try completion.finalPrefix.validate(completion.seal)
        #expect(completion.chapterIndex == 2); #expect(completion.seal.segmentCount == 2)
        #expect(throws: ChapterWorkerError.invalidIdentity) {
            try ChatterboxResolvedBookChapterCompletion(book: book, intent: intent, chapterIndex: 1,
                prepared: pair, seal: seal, finalPrefix: prefix)
        }
        let stored = try #require(await outbox.stored(scopeID: book.scope.identifier))
        let receipt = try ChatterboxBookDemandReceipt(stored: stored, session: session)
        #expect(receipt.confirmedServerRevision == nil)
        #expect(throws: ChapterWorkerError.invalidManifest) {
            try ChatterboxBookServiceUpdate(receipt: receipt, sequence: 1, phase: .complete,
                admittedSpineEntries: 1, completeSpineEntries: 1, totalSpineEntries: 3)
        }
        await outbox.close()
    }
    @Test func historicalPlannerMetadataRestoresWithoutSilentlyPreparingWithNewPlanner() async throws {
        let f = try PreparedBookFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let current = try f.book(session), pair = try f.pair(current, session)
        var object = try #require(JSONSerialization.jsonObject(with: current.scope.configuration) as? [String: Any])
        object["plannerRevision"] = "historical-planner-metadata-only-1"
        let policy = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let scope = try ChapterBookPreparationScope(book: current.scope.book, accountPartition: f.partition, configuration: policy)
        let restored = try ChatterboxPreparedBookSubmission.restore(scope: scope, session: session)
        #expect(!restored.supportsCurrentPlanner); #expect(restored.scope.identifier != current.scope.identifier)
        #expect(throws: ChatterboxChapterRenderPlanError.invalidPlan) {
            try restored.prepareEntry(chapterIndex: 2, text: f.text, session: session)
        }
        let old = pair.submission.request.recipe
        let recipe = try ChapterRenderRecipe(language: old.language, stockVoiceID: old.stockVoiceID,
            conditioningSHA256: old.conditioningSHA256, modelSHA256: old.modelSHA256, rendererProfile: old.rendererProfile,
            plannerRevision: "historical-planner-metadata-only-1", expressionSHA256: old.expressionSHA256,
            synthesisOptionsSHA256: old.synthesisOptionsSHA256, seedPolicy: old.seedPolicy, watermarkRevision: old.watermarkRevision)
        let request = try ChapterRenderRequest(accountPartition: f.partition, source: pair.submission.request.source, recipe: recipe,
            delivery: pair.submission.request.delivery)
        let historical = try ChatterboxPreparedChapterSubmission(submission: .init(request: request, originalText: f.text, session: session), plan: pair.plan)
        #expect(throws: ChatterboxChapterRenderPlanError.invalidPlan) {
            try restored.validate(historical, chapterIndex: 2) // Mixed-era pair is NOT historical compatibility proof.
        }
    }
}
#endif
