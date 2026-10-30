import Foundation
import CryptoKit
import Testing
@testable import LibroxChapterWorker

private actor ReadSetAssetStore: ChapterCloudAssetStore {
    let root: URL
    var record: (String, Data, Data)?
    var inserts = 0, metadataFetches = 0, assetFetches = 0
    var loseAck = false, corrupt = false, pause = false
    var held: URL?
    var waiter: CheckedContinuation<Void, Never>?
    init(root: URL) { self.root = root }
    func configure(lost: Bool = false, corrupt: Bool = false, pause: Bool = false) { loseAck = lost; self.corrupt = corrupt; self.pause = pause }
    func replaceMetadata(_ data: Data) { if let record { self.record = (record.0, data, record.2) } }
    func release() { pause = false; waiter?.resume(); waiter = nil }
    func fetch(key: String, capture: ChapterCloudAssetCapture?) async throws -> ChapterCloudAssetSnapshot? {
        if capture == nil { metadataFetches += 1 } else { assetFetches += 1 }
        guard let record, record.0 == key else { return nil }
        guard let capture else { return .init(key: key, tag: "offline-tag-1", metadata: record.1, file: nil) }
        guard capture.expected.tag == "offline-tag-1", capture.expected.metadata == record.1 else { throw ChapterDemandTransportError.conflict }
        let url = root.appendingPathComponent(UUID().uuidString)
        var data = record.2; if corrupt { data[data.count - 1] ^= 1 }
        try data.write(to: url, options: .withoutOverwriting); defer { try? FileManager.default.removeItem(at: url) }
        let file = try ChapterCloudFileCapture.capture(download: url, expectedBytes: capture.bytes, expectedSHA256: capture.sha256,
            maximum: capture.maximum, session: capture.session, storageDirectory: capture.storage, check: { try Task.checkCancellation() })
        return .init(key: key, tag: "offline-tag-1", metadata: record.1, file: file)
    }
    func insert(key: String, metadata: Data, asset: URL) async throws -> ChapterCloudAssetSnapshot {
        inserts += 1; held = asset
        if pause { await withCheckedContinuation { waiter = $0 } }
        guard record == nil else { throw ChapterDemandTransportError.conflict }
        record = (key, metadata, try Data(contentsOf: asset))
        if loseAck { throw ChapterDemandTransportError.uncertain }
        return .init(key: key, tag: "offline-tag-1", metadata: metadata, file: nil)
    }
}
private final class ReadSetFixture: Sendable {
    let root, captures: URL
    let gate = ChapterAccountSessionGate(), device = UUID()
    let partition = String(repeating: "a", count: 64)
    let store: ReadSetAssetStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        captures = root.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true); store = ReadSetAssetStore(root: root)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func readSet() throws -> ChapterBookReadSet {
        let scope = try ChapterBookPreparationScope(book: .init(bookSHA256: String(repeating: "b", count: 64), extractionRevision: "reader-NFD-1",
            chapterKeys: (0..<1500).map { "spine:\($0):Cafe\u{301}:" + String(repeating: "x", count: 40) }), accountPartition: partition,
            configuration: Data(String(repeating: "exact-explicit-policy-no-backend-grant-", count: 1000).utf8))
        let intent = try ChapterBookDemandIntent(scopeID: scope.identifier, accountPartition: partition, deviceID: device, revision: 3,
            wantedRevision: 1, wanted: true, priority: .init(chapterIndex: 100, sourceUTF16Offset: 0))
        let empty = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        let chapter = ChapterBookStoredChapter(chapterIndex: 0, request: nil, sourceReference: nil, renderPlanReference: nil,
            silentTextSHA256: empty, silentUTF16Length: 0)
        return try ChapterBookReadSet(.init(scope: scope, intent: intent, chapters: [chapter], pending: true, confirmedServerRevision: nil))
    }
    func transport(_ session: ChapterAccountSession) -> ChapterCloudBookReadSetTransport {
        .init(store: store, session: session, gate: gate, captureStorage: captures)
    }
}
@Suite struct ChapterBookReadSetTests {
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    @Test func fullExplicitPolicyOriginalSpineAndUnadmittedGapsRoundtripWithoutLocalReferences() throws {
        let f = try ReadSetFixture(), value = try f.readSet(), bytes = try value.encoded(), identity = try ChapterBookReadSetIdentity(value)
        #expect(bytes.count > 65536)
        let restored = try identity.decodeContent(bytes)
        #expect(restored.scope.configuration == value.scope.configuration); #expect(restored.scope.book.chapterKeys.count == 1500)
        #expect(Data(restored.scope.book.chapterKeys[0].utf8) == Data(value.scope.book.chapterKeys[0].utf8))
        #expect(restored.entries.count == 1); #expect(restored.entries[0].content == nil)
        #expect(restored.intent == value.intent); #expect(try restored.encoded() == bytes)
        #expect(bytes.range(of: Data("sourceReference".utf8)) == nil); #expect(bytes.range(of: Data("contentServerRevision".utf8)) == nil)
    }
    @Test func canonicalOrderingDuplicateIndicesIdentityAndOversizedPayloadsFailClosed() throws {
        let f = try ReadSetFixture(), value = try f.readSet(), bytes = try value.encoded()
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let entries = try #require(object["entries"] as? [[String: Any]])
        object["entries"] = [entries[0], entries[0]]
        let duplicated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        #expect(throws: (any Error).self) { try ChapterBookReadSet.decode(duplicated, expectedSHA256: digest(duplicated),
            accountPartition: f.partition, scopeID: value.scope.identifier, deviceID: f.device) }
        #expect(throws: (any Error).self) { try ChapterBookReadSet.decode(bytes, expectedSHA256: digest(bytes),
            accountPartition: String(repeating: "c", count: 64), scopeID: value.scope.identifier, deviceID: f.device) }
        #expect(throws: (any Error).self) { try ChapterBookReadSet.decode(bytes + Data([32]), expectedSHA256: digest(bytes + Data([32])),
            accountPartition: f.partition, scopeID: value.scope.identifier, deviceID: f.device) }
        #expect(throws: (any Error).self) { try ChapterBookReadSet.decode(Data(repeating: 0, count: ChapterBookReadSet.maximumBytes + 1),
            expectedSHA256: String(repeating: "0", count: 64), accountPartition: f.partition, scopeID: value.scope.identifier, deviceID: f.device) }
    }
    @Test func lostAckReconcilesFullBytesAndNewEpochDownloadsBeforeStagingDisappears() async throws {
        let f = try ReadSetFixture(), value = try f.readSet(), session = try await f.gate.open(accountPartition: f.partition)
        await f.store.configure(lost: true)
        let receipt = try await f.transport(session).upload(value), identity = receipt.identity
        #expect(await f.store.inserts == 1); #expect(await f.store.assetFetches == 1)
        let fresh = try await f.gate.open(accountPartition: f.partition), received = try await f.transport(fresh).download(identity)
        #expect(try received.encoded() == value.encoded())
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await f.transport(session).download(identity) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.captures.path).isEmpty)
    }
    @Test func badMetadataPreventsAssetFetchAndCorruptBytesNeverBecomeAnInsertRetry() async throws {
        let f = try ReadSetFixture(), value = try f.readSet(), session = try await f.gate.open(accountPartition: f.partition), transport = f.transport(session)
        let identity = try await transport.upload(value).identity
        await f.store.replaceMetadata(Data("{}".utf8))
        await #expect(throws: (any Error).self) { try await transport.download(identity) }
        #expect(await f.store.assetFetches == 0)
        await f.store.replaceMetadata(try identity.encoded()); await f.store.configure(corrupt: true)
        await #expect(throws: ChapterCloudFileError.invalidFile) { try await transport.download(identity) }
        #expect(await f.store.inserts == 1); #expect(await f.store.assetFetches == 1)
    }
    @Test func cancelOwnsUncooperativeInsertAndCaptureUntilOriginalCompletion() async throws {
        let f = try ReadSetFixture(), value = try f.readSet(), session = try await f.gate.open(accountPartition: f.partition)
        await f.store.configure(pause: true)
        let producer = Task { try await f.transport(session).upload(value) }
        var held: URL?
        for _ in 0..<1000 { held = await f.store.held; if held != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        let path = try #require(held); producer.cancel()
        #expect(FileManager.default.fileExists(atPath: path.path)); await f.store.release()
        await #expect(throws: CancellationError.self) { try await producer.value }
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
    @Test func capturedDataReadsAreBoundedAndConcurrentWithoutSharedOffsetMutation() async throws {
        let f = try ReadSetFixture(), session = try await f.gate.open(accountPartition: f.partition)
        let bytes = Data((0..<200003).map { UInt8($0 % 251) })
        do {
            let capture = try ChapterCloudFileCapture.create(bytes, maximum: 300000, session: session, storageDirectory: f.captures, check: {})
            async let a = capture.data(session: session, gate: f.gate, maximum: 300000)
            async let b = capture.data(session: session, gate: f.gate, maximum: 300000)
            let values = try await (a, b); #expect(values.0 == bytes && values.1 == bytes)
            await #expect(throws: ChapterCloudFileError.budget) { try await capture.data(session: session, gate: f.gate, maximum: 65536) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.captures.path).isEmpty)
    }
}
