#if os(macOS)
import Foundation
import CryptoKit
import Testing
import LibroxChapterWorker
import LibroxChatterbox
@testable import LibroxChatterboxPlanning

private actor ContentJoinSignal {
    private var names: Set<String> = []
    private var continuations: [String: [CheckedContinuation<Void, Never>]] = [:]
    func signal(_ name: String) { names.insert(name); for c in continuations.removeValue(forKey: name) ?? [] { c.resume() } }
    func wait(_ name: String) async { if !names.contains(name) { await withCheckedContinuation { continuations[name, default: []].append($0) } } }
}
private final class BookContentAdmissionFixture: Sendable {
    let root, sources, plans, content, control: URL
    let partition = String(repeating: "a", count: 64), device = UUID()
    let gate = ChapterAccountSessionGate()
    let text = "Cafe\u{301} 🐈.\r\nSigue."
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sources = root.appendingPathComponent("Sources"); plans = root.appendingPathComponent("Plans")
        content = root.appendingPathComponent("Content"); control = root.appendingPathComponent("BookOutbox")
        for path in [sources, plans, content, control] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func outbox() throws -> ChapterBookOutbox { try .init(directory: control, accountPartition: partition, deviceID: device) }
    func book(_ session: ChapterAccountSession) throws -> ChatterboxPreparedBookSubmission {
        try ChatterboxStockVoiceDescriptor(modelSHA256: String(repeating: "b", count: 64), conditioningSHA256: String(repeating: "c", count: 64),
            rendererProfile: "synthetic-local-content-no-model").prepareBook(source: .init(bookSHA256: String(repeating: "d", count: 64),
                extractionRevision: "reader-1", chapterKeys: ["spine:0", "spine:1"]), settings: .init(language: "es", delivery: .smaller,
                    direction: .storyteller, grouping: .sentences, seed: .max), session: session)
    }
    func budget(maximum: UInt64 = 64 * 1024 * 1024) throws -> ChapterArtifactStorageBudget {
        try .init(controlDirectory: content, managedDirectories: [sources, plans, content],
            policy: .init(maximumManagedBytes: maximum, minimumAvailableBytes: 0))
    }
    func silent(_ book: ChatterboxPreparedBookSubmission, _ session: ChapterAccountSession) throws -> ChatterboxBookEntryContent {
        let text = "\u{FFFC}\r\n\t "
        return try .init(book: book, chapterIndex: 0, originalText: text,
            entry: book.prepareEntry(chapterIndex: 0, text: text, session: session), session: session)
    }
    func chapter(_ book: ChatterboxPreparedBookSubmission, _ session: ChapterAccountSession) throws -> ChatterboxBookEntryContent {
        try .init(book: book, chapterIndex: 1, originalText: text, entry: book.prepareEntry(chapterIndex: 1, text: text, session: session), session: session)
    }
    func admitPair(_ value: ChatterboxBookEntryContent, book: ChatterboxPreparedBookSubmission, outbox: ChapterBookOutbox,
                   budget: ChapterArtifactStorageBudget) async throws {
        guard case .chapter(let pair) = value.entry else { throw ChatterboxChapterRenderPlanError.invalidPlan }
        _ = try await ChatterboxBookSubmissionAdmission.submit(pair, book: book, chapterIndex: value.chapterIndex,
            gate: gate, outbox: outbox, budget: budget, sourceDirectory: sources, planDirectory: plans)
    }
    func persist(_ value: ChatterboxBookEntryContent, book: ChatterboxPreparedBookSubmission, session: ChapterAccountSession,
                 outbox: ChapterBookOutbox, budget: ChapterArtifactStorageBudget,
                 checkpoint: @escaping ChatterboxLocalBookContent.Checkpoint = { _ in }) async throws -> ChapterBookDemandIntent {
        try await ChatterboxLocalBookContent.persist(value, book: book, session: session, gate: gate, outbox: outbox, budget: budget,
            directory: content, sourceDirectory: sources, planDirectory: plans, checkpoint: checkpoint)
    }
}
@Suite struct LocalBookContentTests {
    @Test func foreignAccountOutboxRejectsBeforeEvenEmptyFormatActivationOrArtifactWrites() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), budget = try f.budget(), value = try f.silent(book, session)
        let foreignPartition = String(repeating: "e", count: 64)
        let foreign = try ChapterBookOutbox(directory: f.control, accountPartition: foreignPartition, deviceID: f.device)
        let root = f.control.appendingPathComponent(foreignPartition).appendingPathComponent(f.device.uuidString.lowercased())
        let marker = root.appendingPathComponent("book-established.json"), journal = root.appendingPathComponent("journal.json")
        let markerBefore = try Data(contentsOf: marker), journalBefore = try Data(contentsOf: journal)
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await f.persist(value, book: book, session: session, outbox: foreign, budget: budget) }
        #expect(try Data(contentsOf: marker) == markerBefore); #expect(try Data(contentsOf: journal) == journalBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.content.path) == ["artifact-budget.lock"])
        await foreign.close(); try await budget.close()
    }
    @Test func actualDurablePairAndSilentTextRecoverUnderFreshEpochWithSeparateUploadAcknowledgement() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(), chapter = try f.chapter(book, session)
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 1, sourceUTF16Offset: 0))
        try await f.admitPair(chapter, book: book, outbox: box, budget: budget)
        _ = try await f.persist(chapter, book: book, session: session, outbox: box, budget: budget)
        let silent = try f.silent(book, session)
        let intent = try await f.persist(silent, book: book, session: session, outbox: box, budget: budget)
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).map(\.chapterIndex) == [1, 0])
        let chapterID = try chapter.identity()
        #expect(try await box.confirmContent(chapterID, intent: intent, serverRevision: .init(opaqueValue: "content-server-1")))
        #expect(try await box.stored(scopeID: book.scope.identifier)?.pending == true)
        #expect(try await box.stored(scopeID: book.scope.identifier)?.confirmedServerRevision == nil)
        // A repeated exact source/plan admission preserves immutable content ack.
        try await f.admitPair(chapter, book: book, outbox: box, budget: budget)
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).map(\.chapterIndex) == [0])
        await box.close()
        let fresh = try await f.gate.open(accountPartition: f.partition), reopened = try f.outbox()
        for value in [chapter, silent] {
            let restored = try await ChatterboxLocalBookContent.receive(value.identity(), book: book, session: fresh, gate: f.gate, directory: f.content)
            #expect(try restored.encoded() == value.encoded())
            if case .chapter(let pair) = restored.entry { #expect(pair.submission.session == fresh) }
        }
        #expect(try await reopened.pendingContent(scopeID: book.scope.identifier).map(\.chapterIndex) == [0])
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChatterboxLocalBookContent.receive(chapterID, book: book, session: session, gate: f.gate, directory: f.content)
        }
        await reopened.close(); try await budget.close()
    }
    @Test func missingRealLocalPairCannotAttachOpaquePlanOrPublishContent() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(), chapter = try f.chapter(book, session)
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 1, sourceUTF16Offset: 0))
        await #expect(throws: ChapterBookJournalError.staleAdmission) { try await f.persist(chapter, book: book, session: session, outbox: box, budget: budget) }
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.content.path) == ["artifact-budget.lock"])
        await box.close(); try await budget.close()
    }
    @Test func lostContentAdmissionCallbackReopensActualDurableReferenceAndLiteralBytesWithoutRepublishing() async throws {
        enum LostAck: Error { case simulated }
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(), value = try f.silent(book, session)
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        await #expect(throws: LostAck.self) {
            try await f.persist(value, book: book, session: session, outbox: box, budget: budget) { event in
                if case .afterIntent = event { throw LostAck.simulated }
            }
        }
        await box.close()
        let fresh = try await f.gate.open(accountPartition: f.partition), reopened = try f.outbox()
        let pending = try #require(await reopened.pendingContent(scopeID: book.scope.identifier).first), identity = try #require(pending.contentIdentity)
        #expect(identity == (try value.identity()))
        let actual = try await ChatterboxLocalBookContent.receive(identity, book: book, session: fresh, gate: f.gate, directory: f.content)
        #expect(try actual.encoded() == value.encoded()); #expect(pending.contentServerRevision == nil)
        #expect(try await reopened.stored(scopeID: book.scope.identifier)?.pending == true)
        await reopened.close(); try await budget.close()
    }
    @Test func changedAuthoredPlanInvalidatesOldUploadIdentityAndAckButPreservesOriginalImmutableContent() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(), original = try f.chapter(book, session)
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 1, sourceUTF16Offset: 0))
        try await f.admitPair(original, book: book, outbox: box, budget: budget)
        let before = try await f.persist(original, book: book, session: session, outbox: box, budget: budget), oldIdentity = try original.identity()
        #expect(try await box.confirmContent(oldIdentity, intent: before, serverRevision: .init(opaqueValue: "old-content-ack")))
        let directions = try ChatterboxPerformanceDirections(source: f.text, annotations: [
            .init(range: NSRange(location: 0, length: f.text.utf16.count), originalText: f.text,
                performance: .init(delivery: .soft, strength: .subtle), controls: .init(exaggeration: 1.1, guidance: 0.3, temperature: 0.8))
        ], scope: .chapterV1)
        let revised = try ChatterboxBookEntryContent(book: book, chapterIndex: 1, originalText: f.text,
            entry: book.prepareEntry(chapterIndex: 1, text: f.text, performanceDirections: directions, session: session), session: session)
        try await f.admitPair(revised, book: book, outbox: box, budget: budget)
        let stored = try #require(await box.stored(scopeID: book.scope.identifier)), chapter = try #require(stored.chapters.first)
        #expect(stored.intent.wantedRevision == before.wantedRevision); #expect(stored.intent.revision > before.revision)
        #expect(chapter.contentIdentity == nil); #expect(chapter.contentServerRevision == nil)
        #expect(try await box.confirmContent(oldIdentity, intent: before, serverRevision: .init(opaqueValue: "late-old-ack")) == false)
        _ = try await f.persist(revised, book: book, session: session, outbox: box, budget: budget)
        #expect(try revised.identity() != oldIdentity)
        #expect(FileManager.default.fileExists(atPath: f.content.appendingPathComponent(oldIdentity.payloadSHA256 + ".json").path))
        await box.close(); try await budget.close()
    }
    @Test func lateCancelRerequestAfterPublicationPreservesCompleteBlobWithoutResurrectingAdmission() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(), value = try f.silent(book, session), signal = ContentJoinSignal()
        let priority = try ChapterBookPriority(chapterIndex: 0, sourceUTF16Offset: 0)
        _ = try await box.setWanted(true, scope: book.scope, priority: priority)
        let producer = Task {
            try await f.persist(value, book: book, session: session, outbox: box, budget: budget) { event in
                if case .beforeIntent = event { await signal.signal("ready"); await signal.wait("release") }
            }
        }
        await signal.wait("ready")
        _ = try await box.setWanted(false, scope: book.scope, priority: priority)
        _ = try await box.setWanted(true, scope: book.scope, priority: priority)
        await signal.signal("release")
        await #expect(throws: ChapterBookJournalError.staleAdmission) { try await producer.value }
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.content.appendingPathComponent(try value.identity().payloadSHA256 + ".json").path))
        await box.close(); try await budget.close()
    }
    @Test func cancellationJoinsUncooperativeProducerBeforeReleasingArtifactAllowance() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(), value = try f.silent(book, session), signal = ContentJoinSignal()
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        let producer = Task {
            try await f.persist(value, book: book, session: session, outbox: box, budget: budget) { event in
                if case .afterPublish = event { await signal.signal("ready"); await signal.wait("release") }
            }
        }
        await signal.wait("ready"); producer.cancel()
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        await signal.signal("release")
        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).isEmpty)
        await box.close(); try await budget.close()
    }
    @Test func capacityFailureLeavesControlWritesAvailableAndDoesNotDeleteUnknownOrCompletedFiles() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(maximum: 8 * 1024 * 1024), value = try f.silent(book, session)
        let priority = try ChapterBookPriority(chapterIndex: 0, sourceUTF16Offset: 0), unknown = f.content.appendingPathComponent("unknown.keep")
        try Data([1, 2, 3]).write(to: unknown)
        _ = try await box.setWanted(true, scope: book.scope, priority: priority)
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await f.persist(value, book: book, session: session, outbox: box, budget: budget) }
        #expect(try await box.setWanted(false, scope: book.scope, priority: priority).wanted == false)
        #expect(try Data(contentsOf: unknown) == Data([1, 2, 3]))
        await box.close(); try await budget.close()
    }
    @Test func lateUploadAckAndMissingCorruptContentNeverAcknowledgeCurrentBookOrBecomePlayable() async throws {
        let f = try BookContentAdmissionFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let book = try f.book(session), box = try f.outbox(), budget = try f.budget(), value = try f.silent(book, session)
        let priority = try ChapterBookPriority(chapterIndex: 0, sourceUTF16Offset: 0)
        _ = try await box.setWanted(true, scope: book.scope, priority: priority)
        let old = try await f.persist(value, book: book, session: session, outbox: box, budget: budget), identity = try value.identity()
        _ = try await box.setWanted(false, scope: book.scope, priority: priority)
        _ = try await box.setWanted(true, scope: book.scope, priority: priority)
        #expect(try await box.confirmContent(identity, intent: old, serverRevision: .init(opaqueValue: "late")) == false)
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).count == 1)
        let file = f.content.appendingPathComponent(identity.payloadSHA256 + ".json")
        try Data("corrupt replacement".utf8).write(to: file, options: .atomic)
        await #expect(throws: (any Error).self) {
            try await ChatterboxLocalBookContent.receive(identity, book: book, session: session, gate: f.gate, directory: f.content)
        }
        #expect(try await box.stored(scopeID: book.scope.identifier)?.pending == true)
        await box.close(); try await budget.close()
    }
}
#endif
