#if os(macOS)
import Foundation
import CryptoKit
import Testing
import LibroxChatterbox
@testable import LibroxChapterWorker
@testable import LibroxChatterboxPlanning

private actor PendingUploadStore: ChapterCloudBookEntryStore {
    let root: URL
    var record: (String, Data, Data)?
    var inserts = 0, assetFetches = 0, metadataFetches = 0
    var loseAck = false, pause = false
    var held: URL?
    var continuation: CheckedContinuation<Void, Never>?
    init(root: URL) { self.root = root }
    func configure(lostAck: Bool = false, pause: Bool = false) { loseAck = lostAck; self.pause = pause }
    func release() { pause = false; continuation?.resume(); continuation = nil }
    func fetch(key: String, capture: ChapterCloudBookEntryCapture?) async throws -> ChapterCloudBookEntrySnapshot? {
        if capture == nil { metadataFetches += 1 } else { assetFetches += 1 }
        guard let record, record.0 == key else { return nil }
        guard let capture else { return .init(key: key, tag: "offline-record-tag-1", metadata: record.1, file: nil) }
        guard capture.expected.metadata == record.1, capture.expected.tag == "offline-record-tag-1" else { throw ChapterCloudBookEntryError.conflict }
        let url = root.appendingPathComponent("staging-" + UUID().uuidString)
        try record.2.write(to: url, options: .withoutOverwriting); defer { try? FileManager.default.removeItem(at: url) }
        let file = try ChapterCloudFileCapture.capture(download: url, expectedBytes: capture.identity.byteCount,
            expectedSHA256: capture.identity.payloadSHA256, maximum: ChapterBookEntryContentIdentity.maximumBytes,
            session: capture.session, storageDirectory: capture.storage, check: { try Task.checkCancellation() })
        return .init(key: key, tag: "offline-record-tag-1", metadata: record.1, file: file)
    }
    func insert(key: String, metadata: Data, content: URL) async throws -> ChapterCloudBookEntrySnapshot {
        inserts += 1; held = content
        if pause { await withCheckedContinuation { continuation = $0 } }
        let bytes = try Data(contentsOf: content)
        guard record == nil else { throw ChapterDemandTransportError.conflict }
        record = (key, metadata, bytes)
        if loseAck { throw ChapterDemandTransportError.uncertain }
        return .init(key: key, tag: "offline-record-tag-1", metadata: metadata, file: nil)
    }
}
private actor UploadSignal {
    private var ready = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async { ready = true; waiter?.resume(); waiter = nil; if !released { await withCheckedContinuation { releaseWaiter = $0 } } }
    func awaitReady() async { if !ready { await withCheckedContinuation { waiter = $0 } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
private final class PendingUploadFixture: Sendable {
    let root, sources, plans, content, captures, control: URL
    let partition = String(repeating: "a", count: 64), device = UUID()
    let gate = ChapterAccountSessionGate()
    let store: PendingUploadStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        sources = root.appendingPathComponent("Sources"); plans = root.appendingPathComponent("Plans")
        content = root.appendingPathComponent("Content"); captures = root.appendingPathComponent("Captures"); control = root.appendingPathComponent("Books")
        for p in [sources, plans, content, captures, control] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true) }
        store = PendingUploadStore(root: root)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func outbox() throws -> ChapterBookOutbox { try .init(directory: control, accountPartition: partition, deviceID: device) }
    func budget() throws -> ChapterArtifactStorageBudget {
        try .init(controlDirectory: content, managedDirectories: [sources, plans, content, captures],
            policy: .init(maximumManagedBytes: 80 * 1024 * 1024, minimumAvailableBytes: 0))
    }
    func prepare(_ session: ChapterAccountSession, box: ChapterBookOutbox, budget: ChapterArtifactStorageBudget,
                 text: String = "\u{FFFC}\r\n", directions: ChatterboxPerformanceDirections? = nil) async throws -> ChatterboxPreparedBookSubmission {
        let book = try ChatterboxStockVoiceDescriptor(modelSHA256: String(repeating: "b", count: 64),
            conditioningSHA256: String(repeating: "c", count: 64), rendererProfile: "offline-upload-fixture-no-model")
            .prepareBook(source: .init(bookSHA256: String(repeating: "d", count: 64), extractionRevision: "reader-1", chapterKeys: ["spine:0"]),
                settings: .init(language: "en", delivery: .smaller, direction: .storyteller, grouping: .sentences, seed: 42), session: session)
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        let entry = try book.prepareEntry(chapterIndex: 0, text: text, performanceDirections: directions, session: session)
        if case .chapter(let pair) = entry {
            _ = try await ChatterboxBookSubmissionAdmission.submit(pair, book: book, chapterIndex: 0, gate: gate, outbox: box,
                budget: budget, sourceDirectory: sources, planDirectory: plans)
        }
        let value = try ChatterboxBookEntryContent(book: book, chapterIndex: 0, originalText: text, entry: entry, session: session)
        _ = try await ChatterboxLocalBookContent.persist(value, book: book, session: session, gate: gate, outbox: box,
            budget: budget, directory: content, sourceDirectory: sources, planDirectory: plans)
        return book
    }
    func upload(_ book: ChatterboxPreparedBookSubmission, _ session: ChapterAccountSession, _ box: ChapterBookOutbox,
                _ budget: ChapterArtifactStorageBudget, checkpoint: @escaping ChatterboxBookContentUpload.Checkpoint = { _ in }) async throws -> ChapterBookContentServerReceipt? {
        let transport = ChapterCloudBookEntryTransport(store: store, session: session, gate: gate, captureStorage: captures)
        return try await ChatterboxBookContentUpload.reconcileOne(book: book, session: session, gate: gate, outbox: box, directory: content,
            budget: budget, transport: transport, checkpoint: checkpoint)
    }
}
@Suite struct BookContentUploadTests {
    private func directions(_ text: String, exaggeration: Float) throws -> ChatterboxPerformanceDirections {
        try .init(source: text, annotations: [.init(range: NSRange(location: 0, length: text.utf16.count), originalText: text,
            performance: .init(delivery: .soft, strength: .subtle), controls: .init(exaggeration: exaggeration, guidance: 0.3, temperature: 0.8))], scope: .chapterV1)
    }
    @Test func narratedAuthoredPlanTransfersActualAdmittedSourceAndEveryControlBit() async throws {
        let f = try PendingUploadFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let box = try f.outbox(), budget = try f.budget(), text = "Cafe\u{301} 🐈.\r\nSigue."
        let book = try await f.prepare(session, box: box, budget: budget, text: text, directions: directions(text, exaggeration: Float(bitPattern: 0x80000000)))
        let original = try #require(await box.observePendingContentUpload(scopeID: book.scope.identifier))
        let receipt = try #require(await f.upload(book, session, box, budget)), wire = try #require(await f.store.record)
        let actual = try ChatterboxBookEntryContent.decode(wire.2, identity: receipt.identity, book: book, chapterIndex: 0, session: session)
        guard case .chapter(let pair) = actual.entry else { Issue.record("Narrated entry lost"); return }
        #expect(Data(pair.submission.originalText.utf8) == Data(text.utf8))
        #expect(try pair.submission.request.renderKey() == original.chapter.request?.renderKey())
        let options = try pair.plan.restore(source: text)
        #expect(options.performanceDirections?.annotations.first?.controls?.exaggeration.bitPattern == 0x80000000)
        #expect(options.seed == 42); #expect(options.delivery == .smaller)
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).isEmpty)
        await box.close(); try await budget.close()
    }
    @Test func replacedAdmittedAuthoredRequestRejectsStaleButValidContentBeforeAnyStoreIO() async throws {
        let f = try PendingUploadFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let box = try f.outbox(), budget = try f.budget(), text = "Same exact source."
        let book = try await f.prepare(session, box: box, budget: budget, text: text, directions: directions(text, exaggeration: 0.4))
        let old = try #require(await box.observePendingContentUpload(scopeID: book.scope.identifier)), oldIdentity = try #require(old.chapter.contentIdentity)
        guard case .chapter(let revised) = try book.prepareEntry(chapterIndex: 0, text: text,
            performanceDirections: directions(text, exaggeration: 1.4), session: session) else { Issue.record("Missing revised pair"); return }
        _ = try await ChatterboxBookSubmissionAdmission.submit(revised, book: book, chapterIndex: 0, gate: f.gate, outbox: box,
            budget: budget, sourceDirectory: f.sources, planDirectory: f.plans)
        await box.close()
        // Checksummed inconsistent metadata is a safety fixture: restore a valid
        // OLD blob reference alongside the actual NEW admitted authored request.
        let path = f.control.appendingPathComponent(f.partition).appendingPathComponent(f.device.uuidString.lowercased()).appendingPathComponent("journal.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var value = try #require(object["value"] as? [String: Any]), entries = try #require(value["entries"] as? [String: Any])
        var entry = try #require(entries[book.scope.identifier] as? [String: Any]), chapters = try #require(entry["chapters"] as? [String: Any])
        var chapter = try #require(chapters["0"] as? [String: Any])
        chapter["contentIdentity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldIdentity))
        chapters["0"] = chapter; entry["chapters"] = chapters; entries[book.scope.identifier] = entry; value["entries"] = entries; object["value"] = value
        let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        object["checksum"] = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: path, options: .atomic)
        let reopened = try f.outbox()
        await #expect(throws: ChapterBookJournalError.staleAdmission) { try await f.upload(book, session, reopened, budget) }
        #expect(await f.store.inserts == 0); #expect(await f.store.metadataFetches == 0)
        #expect(try await reopened.pendingContent(scopeID: book.scope.identifier).count == 1)
        await reopened.close(); try await budget.close()
    }
    @Test func actualStoreReceiptConfirmsContentOnlyAndUnchangedQueueDoesNoMoreIO() async throws {
        let f = try PendingUploadFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let box = try f.outbox(), budget = try f.budget(), book = try await f.prepare(session, box: box, budget: budget)
        await f.store.configure(lostAck: true)
        let receipt = try #require(await f.upload(book, session, box, budget))
        #expect(receipt.session == session); #expect(await f.store.inserts == 1); #expect(await f.store.assetFetches == 1)
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).isEmpty)
        let snapshot = try #require(await box.stored(scopeID: book.scope.identifier))
        #expect(snapshot.pending); #expect(snapshot.confirmedServerRevision == nil)
        #expect(snapshot.chapters.first?.contentServerRevision == receipt.revision.opaqueValue)
        let before = await f.store.metadataFetches
        #expect(try await f.upload(book, session, box, budget) == nil)
        #expect(await f.store.metadataFetches == before); #expect(await f.store.inserts == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.captures.path) == ["artifact-budget.lock"])
        await box.close(); try await budget.close()
    }
    @Test func lostLocalConfirmationRecoversViaActualExistingBytesUnderFreshEpoch() async throws {
        enum LostCallback: Error { case simulated }
        let f = try PendingUploadFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let box = try f.outbox(), budget = try f.budget(), book = try await f.prepare(session, box: box, budget: budget)
        await #expect(throws: LostCallback.self) {
            try await f.upload(book, session, box, budget) { event in if case .beforeConfirmation = event { throw LostCallback.simulated } }
        }
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).count == 1)
        await box.close()
        let fresh = try await f.gate.open(accountPartition: f.partition), reopened = try f.outbox()
        let receipt = try #require(await f.upload(book, fresh, reopened, budget))
        #expect(receipt.session == fresh); #expect(await f.store.inserts == 1); #expect(await f.store.assetFetches == 1)
        #expect(try await reopened.pendingContent(scopeID: book.scope.identifier).isEmpty)
        await reopened.close(); try await budget.close()
    }
    @Test func cancelJoinsBlockedOriginalTransferBeforeAllowanceAndCaptureRelease() async throws {
        let f = try PendingUploadFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let box = try f.outbox(), budget = try f.budget(), book = try await f.prepare(session, box: box, budget: budget)
        await f.store.configure(pause: true)
        let producer = Task { try await f.upload(book, session, box, budget) }
        var held: URL?
        for _ in 0..<1000 { held = await f.store.held; if held != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        let file = try #require(held); producer.cancel()
        #expect(FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        await f.store.release()
        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(!FileManager.default.fileExists(atPath: file.path)); #expect(try await box.pendingContent(scopeID: book.scope.identifier).count == 1)
        await box.close(); try await budget.close()
    }
    @Test func lateCancelRerequestCannotConfirmOldReceiptButPreservesContentForFiniteReconciliation() async throws {
        let f = try PendingUploadFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let box = try f.outbox(), budget = try f.budget(), book = try await f.prepare(session, box: box, budget: budget), signal = UploadSignal()
        let producer = Task {
            try await f.upload(book, session, box, budget) { event in if case .beforeConfirmation = event { await signal.hold() } }
        }
        await signal.awaitReady()
        _ = try await box.setWanted(false, scope: book.scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        _ = try await box.setWanted(true, scope: book.scope, priority: .init(chapterIndex: 0, sourceUTF16Offset: 0))
        await signal.release()
        await #expect(throws: ChapterBookJournalError.staleAdmission) { try await producer.value }
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).count == 1)
        _ = try await f.upload(book, session, box, budget)
        #expect(await f.store.inserts == 1); #expect(await f.store.assetFetches == 1)
        await box.close(); try await budget.close()
    }
    @Test func corruptLocalContentFailsBeforeAnyStoreOperationAndRemainsPending() async throws {
        let f = try PendingUploadFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let box = try f.outbox(), budget = try f.budget(), book = try await f.prepare(session, box: box, budget: budget)
        let entry = try #require(await box.pendingContent(scopeID: book.scope.identifier).first), identity = try #require(entry.contentIdentity)
        try Data("wrong content".utf8).write(to: f.content.appendingPathComponent(identity.payloadSHA256 + ".json"), options: .atomic)
        await #expect(throws: (any Error).self) { try await f.upload(book, session, box, budget) }
        #expect(await f.store.inserts == 0); #expect(await f.store.metadataFetches == 0)
        #expect(try await box.pendingContent(scopeID: book.scope.identifier).count == 1)
        await box.close(); try await budget.close()
    }
}
#endif
