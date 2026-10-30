import Foundation
import Testing
@testable import LibroxChapterWorker

private actor BookContentStore: ChapterCloudBookEntryStore {
    let root: URL
    var record: (key: String, metadata: Data, bytes: Data)?
    var inserts = 0, metadataFetches = 0, contentFetches = 0
    var loseAck = false, corrupt = false, pauseInsert = false
    var insertedURL: URL?
    var waiter: CheckedContinuation<Void, Never>?
    init(root: URL) { self.root = root }
    func configure(lostAck: Bool = false, corrupt: Bool = false, pause: Bool = false) {
        loseAck = lostAck; self.corrupt = corrupt; pauseInsert = pause
    }
    func release() { pauseInsert = false; waiter?.resume(); waiter = nil }
    func replaceMetadata(_ bytes: Data) { if let record { self.record = (record.key, bytes, record.bytes) } }
    func fetch(key: String, capture: ChapterCloudBookEntryCapture?) async throws -> ChapterCloudBookEntrySnapshot? {
        if capture == nil { metadataFetches += 1 } else { contentFetches += 1 }
        guard let record, record.key == key else { return nil }
        if let capture {
            guard capture.expected.metadata == record.metadata, capture.expected.tag == "tag1" else { throw ChapterCloudBookEntryError.conflict }
            var bytes = record.bytes; if corrupt { bytes[bytes.count - 1] ^= 1 }
            let staging = root.appendingPathComponent("incoming-" + UUID().uuidString)
            try bytes.write(to: staging, options: .withoutOverwriting); defer { try? FileManager.default.removeItem(at: staging) }
            let file = try ChapterCloudFileCapture.capture(download: staging, expectedBytes: capture.identity.byteCount,
                expectedSHA256: capture.identity.payloadSHA256, maximum: ChapterBookEntryContentIdentity.maximumBytes,
                session: capture.session, storageDirectory: capture.storage, check: { try Task.checkCancellation() })
            // The staging URL disappears before this awaited store returns.
            return .init(key: key, tag: "tag1", metadata: record.metadata, file: file)
        }
        return .init(key: key, tag: "tag1", metadata: record.metadata, file: nil)
    }
    func insert(key: String, metadata: Data, content: URL) async throws -> ChapterCloudBookEntrySnapshot {
        inserts += 1; insertedURL = content
        if pauseInsert { await withCheckedContinuation { waiter = $0 } }
        let bytes = try Data(contentsOf: content)
        guard record == nil else { throw ChapterDemandTransportError.conflict }
        record = (key, metadata, bytes)
        if loseAck { throw ChapterDemandTransportError.uncertain }
        return .init(key: key, tag: "tag1", metadata: metadata, file: nil)
    }
}
private final class BookContentFixture: Sendable {
    let root, capture: URL
    let gate = ChapterAccountSessionGate()
    let store: BookContentStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        capture = root.appendingPathComponent("Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        store = BookContentStore(root: root)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func identity(_ session: ChapterAccountSession, _ data: Data) throws -> ChapterBookEntryContentIdentity {
        try .init(accountPartition: session.accountPartition, scopeID: String(repeating: "b", count: 64), chapterIndex: 14, kind: .chapter, payload: data)
    }
    func transport(_ session: ChapterAccountSession, authorize: @escaping @Sendable () async throws -> Void = {}) -> ChapterCloudBookEntryTransport {
        .init(store: store, session: session, gate: gate, captureStorage: capture, authorize: authorize)
    }
}
@Suite struct ChapterCloudBookEntryTransportTests {
    @Test func callbackCaptureLostAckAndFreshEpochPreserveExactContentBeyond64KiB() async throws {
        let f = try BookContentFixture(), sender = try await f.gate.open(accountPartition: String(repeating: "a", count: 64))
        let bytes = Data(String(repeating: "Cafe\u{301}\r\n\u{FFFC}\u{0} 🐈", count: 10000).utf8), identity = try f.identity(sender, bytes)
        await f.store.configure(lostAck: true)
        try await f.transport(sender).upload(bytes, identity: identity)
        #expect(await f.store.inserts == 1); #expect(await f.store.contentFetches == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.capture.path).isEmpty)
        let receiver = try await f.gate.open(accountPartition: sender.accountPartition)
        #expect(try await f.transport(receiver).download(identity) == bytes)
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await f.transport(sender).download(identity) }
        #expect(await f.store.inserts == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.capture.path).isEmpty)
    }
    @Test func BadMetadataStopsBeforeAssetAndCorruptBytesDoNotRetryOrUploadAgain() async throws {
        let f = try BookContentFixture(), session = try await f.gate.open(accountPartition: String(repeating: "a", count: 64))
        let bytes = Data("exact source and portable plan".utf8), identity = try f.identity(session, bytes), transport = f.transport(session)
        try await transport.upload(bytes, identity: identity)
        await f.store.replaceMetadata(Data("{}".utf8))
        await #expect(throws: (any Error).self) { try await transport.download(identity) }
        #expect(await f.store.contentFetches == 0)
        await f.store.replaceMetadata(try identity.encoded()); await f.store.configure(corrupt: true)
        await #expect(throws: ChapterCloudFileError.invalidFile) { try await transport.download(identity) }
        #expect(await f.store.inserts == 1); #expect(await f.store.contentFetches == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.capture.path).isEmpty)
    }
    @Test func cancelledUncooperativeInsertRetainsPrivateFileUntilOriginalCompletionThenRejects() async throws {
        let f = try BookContentFixture(), session = try await f.gate.open(accountPartition: String(repeating: "a", count: 64))
        let bytes = Data(repeating: 42, count: 70001), identity = try f.identity(session, bytes), transport = f.transport(session)
        await f.store.configure(pause: true)
        let producer = Task { try await transport.upload(bytes, identity: identity) }
        var url: URL?
        for _ in 0..<1000 {
            url = await f.store.insertedURL
            if url != nil { break }; try await Task.sleep(for: .milliseconds(2))
        }
        let held = try #require(url); producer.cancel()
        #expect(FileManager.default.fileExists(atPath: held.path))
        await f.store.release()
        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(!FileManager.default.fileExists(atPath: held.path))
        #expect(await f.store.inserts == 1)
    }
    @Test func liveAuthorizationAndForeignAccountRejectBeforeNativeStoreCalls() async throws {
        let f = try BookContentFixture(), session = try await f.gate.open(accountPartition: String(repeating: "a", count: 64))
        let bytes = Data("not a grant".utf8), identity = try f.identity(session, bytes)
        let revoked = f.transport(session) { _ = try await f.gate.open(accountPartition: session.accountPartition) }
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await revoked.upload(bytes, identity: identity) }
        #expect(await f.store.inserts == 0); #expect(await f.store.metadataFetches == 0)
        #expect(throws: (any Error).self) { try ChapterBookEntryContentIdentity(accountPartition: session.accountPartition,
            scopeID: String(repeating: "b", count: 64), chapterIndex: 0, kind: .silent, payload: Data()) }
        #expect(throws: (any Error).self) { try identity.verify(bytes + Data([0])) }
    }
}
