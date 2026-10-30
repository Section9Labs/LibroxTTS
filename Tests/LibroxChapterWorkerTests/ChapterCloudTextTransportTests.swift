import Foundation
import Testing
import CryptoKit
import Synchronization
@testable import LibroxChapterWorker

private actor SourceTransferBarrier {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaser: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; waiter?.resume(); waiter = nil
        await withCheckedContinuation { releaser = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { waiter = $0 } } }
    func release() { releaser?.resume(); releaser = nil }
}
private actor SourceTransferCounter {
    var count = 0
    var finished = false
    func next() -> Int { count += 1; return count }
    func finish() { finished = true }
}
private actor SourceStoreFixture: ChapterSourceRecordStore {
    let server: URL
    var current: ChapterSourceSnapshot?
    var calls: [String] = []
    var writes = 0
    var insertFailure: ChapterSourceTransportError?
    var loseAck = false
    var changeTag = false
    var barrier: SourceTransferBarrier?
    var heldFile: URL?
    var captureThenDelete = false
    init(server: URL) { self.server = server }
    func configure(_ snapshot: ChapterSourceSnapshot?, lostAck: Bool = false,
                   failure: ChapterSourceTransportError? = nil, changeTag: Bool = false,
                   barrier: SourceTransferBarrier? = nil, captureThenDelete: Bool = false) {
        current = snapshot; loseAck = lostAck; insertFailure = failure
        self.changeTag = changeTag; self.barrier = barrier; self.captureThenDelete = captureThenDelete
    }
    func fetch(key: String, asset: Bool, capture: ChapterSourceCapture?) async throws -> ChapterSourceSnapshot? {
        calls.append(asset ? "asset" : "metadata")
        guard let value = current else { return nil }
        if asset {
            if captureThenDelete {
                guard let capture, let url = value.file else { throw ChapterSourceTransportError.invalidRecord }
                var saved = value
                saved.captured = try ChapterTextAsset.captureDownloadedFile(download: url,
                    manifest: capture.manifest, request: capture.request, session: capture.session,
                    storageDirectory: capture.storage, check: { try Task.checkCancellation() })
                try FileManager.default.removeItem(at: url)
                return saved
            }
            return value
        }
        if changeTag {
            current = .init(key: value.key, type: value.type, tag: "changed-tag", payload: value.payload,
                file: value.file, lifetime: nil)
        }
        return .init(key: value.key, type: value.type, tag: value.tag, payload: value.payload, file: nil, lifetime: nil)
    }
    func insert(key: String, payload: Data, file: URL) async throws -> ChapterSourceSnapshot {
        calls.append("insert"); heldFile = file
        if let barrier { await barrier.hold() } // Deliberately ignores cancellation until the owned operation completes.
        if let insertFailure { throw insertFailure }
        guard current == nil else { throw ChapterSourceTransportError.conflict }
        let uploaded = server.appendingPathComponent("source.utf8")
        try FileManager.default.copyItem(at: file, to: uploaded)
        writes += 1
        let record = ChapterSourceSnapshot(key: key, type: ChapterCloudTextTransport.recordType,
            tag: "source-v1", payload: payload, file: uploaded, lifetime: nil)
        current = record
        if loseAck { throw ChapterSourceTransportError.cloud(.uncertain) }
        return record
    }
}
private final class CloudSourceFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage, server, incoming: URL
    let gate = ChapterAccountSessionGate()
    let store: SourceStoreFixture
    init() throws {
        storage = root.appendingPathComponent("owned"); server = root.appendingPathComponent("server")
        incoming = root.appendingPathComponent("incoming.utf8")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        store = .init(server: server)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func request(_ text: String, partition: String = String(repeating: "a", count: 64),
                 delivery: ChapterAudioDelivery = .smaller) throws -> ChapterRenderRequest {
        try .init(accountPartition: partition,
            source: .init(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:4",
                textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
                extractionRevision: "exact-1", utf16Length: text.utf16.count),
            recipe: .init(language: "es", stockVoiceID: "stock", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "standard", plannerRevision: "chapter-1",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-42", watermarkRevision: "disabled-1"), delivery: delivery)
    }
    func open() async throws -> ChapterAccountSession { try await gate.open(accountPartition: String(repeating: "a", count: 64)) }
    func transport(_ session: ChapterAccountSession, authorize: @escaping @Sendable () async throws -> Void = {}) -> ChapterCloudTextTransport {
        .init(store: store, session: session, gate: gate, storageDirectory: storage, authorize: authorize)
    }
    func snapshot(text: String, request: ChapterRenderRequest, tag: String = "source-v1", type: String = ChapterCloudTextTransport.recordType,
                  key: String? = nil, payload: Data? = nil) throws -> ChapterSourceSnapshot {
        let manifest = try ChapterTextAssetManifest(request: request, byteCount: text.utf8.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try Data(text.utf8).write(to: incoming)
        return try .init(key: key ?? manifest.sourceKey(), type: type, tag: tag,
            payload: payload ?? encoder.encode(manifest), file: incoming, lifetime: nil)
    }
}

@Suite(.serialized) struct ChapterCloudTextTransportTests {
    @Test func exactUploadAndDownloadHaveDifferentEvidenceAndPrivateCustody() async throws {
        let f = try CloudSourceFixture(), session = try await f.open()
        let text = String(repeating: "A\r\ne\u{301}🙂\u{fffc}終\n", count: 6000), request = try f.request(text)
        let submission = try ChapterSubmission(request: request, originalText: text, session: session)
        let asset = try await ChapterTextAsset.create(submission, gate: f.gate, storageDirectory: f.storage)
        let transport = f.transport(session), uploaded = try await transport.publish(asset, request: request, session: session)
        #expect(uploaded.evidence == .acknowledgedUpload)
        #expect(uploaded.session == session && uploaded.manifest == asset.manifest)
        let downloaded = try await transport.download(request: request, session: session)
        #expect(downloaded.receipt.evidence == .verifiedDownload)
        #expect(downloaded.receipt.revision == uploaded.revision)
        #expect(Data(try await downloaded.asset.text(session: session, gate: f.gate).utf8) == Data(text.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.server.appendingPathComponent("source.utf8").path)
        try Data("changed server".utf8).write(to: f.server.appendingPathComponent("source.utf8"))
        #expect(Data(try await downloaded.asset.text(session: session, gate: f.gate).utf8) == Data(text.utf8))
        #expect(await f.store.writes == 1)
    }
    @Test func lostAckReconcilesOnceUsingVerifiedDownloadAndLiveAuthorization() async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = "Hola\r\n🙂 e\u{301}", request = try f.request(text)
        await f.store.configure(nil, lostAck: true)
        let counter = SourceTransferCounter()
        let transport = f.transport(session) { _ = await counter.next() }
        let asset = try await ChapterTextAsset.create(.init(request: request, originalText: text, session: session), gate: f.gate, storageDirectory: f.storage)
        let receipt = try await transport.publish(asset, request: request, session: session)
        #expect(receipt.evidence == .verifiedDownload)
        #expect(await f.store.calls == ["metadata", "insert", "metadata", "asset"])
        #expect(await counter.count == 4)
        #expect(await f.store.writes == 1)
        let lossless = try f.request(text, delivery: .lossless)
        _ = try await transport.publish(asset, request: lossless, session: session)
        #expect(await f.store.writes == 1)
        #expect(try asset.manifest.sourceKey() == ChapterTextAssetManifest.sourceKey(for: lossless.source))
    }
    @Test(arguments: ["partition", "key", "type", "payload", "version"])
    func invalidMetadataRejectsBeforeAssetRequest(_ fault: String) async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = "Hola 🙂", request = try f.request(text)
        let other = try f.request(text, partition: String(repeating: "1", count: 64))
        var snapshot = try f.snapshot(text: text, request: fault == "partition" ? other : request,
            type: fault == "type" ? "wrong" : ChapterCloudTextTransport.recordType,
            key: fault == "key" ? String(repeating: "0", count: 64) : nil,
            payload: fault == "payload" ? Data(repeating: 0, count: 128 * 1024 + 1) : nil)
        if fault == "version" {
            var d = try #require(JSONSerialization.jsonObject(with: snapshot.payload) as? [String: Any]); d["version"] = 99
            snapshot = .init(key: snapshot.key, type: snapshot.type, tag: snapshot.tag,
                payload: try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]), file: snapshot.file, lifetime: nil)
        }
        await f.store.configure(snapshot)
        await #expect(throws: ChapterSourceTransportError.invalidRecord) { try await f.transport(session).download(request: request, session: session) }
        #expect(await f.store.calls == ["metadata"])
    }
    @Test func changedTagAndCorruptBytesNeverBecomeAcceptedCustody() async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = "Exacta\r\n🙂", request = try f.request(text)
        let snapshot = try f.snapshot(text: text, request: request)
        await f.store.configure(snapshot, changeTag: true)
        await #expect(throws: ChapterSourceTransportError.conflict) { try await f.transport(session).download(request: request, session: session) }
        await f.store.configure(snapshot)
        try Data(repeating: 65, count: text.utf8.count).write(to: f.incoming)
        await #expect(throws: ChapterTextAssetError.invalidUTF8) { try await f.transport(session).download(request: request, session: session) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.incoming.path))
    }
    @Test func epochRevokedAtSecondAuthorizationNeverFetchesAsset() async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = "Hola", request = try f.request(text)
        await f.store.configure(try f.snapshot(text: text, request: request))
        let counter = SourceTransferCounter()
        let transport = f.transport(session) {
            if await counter.next() == 2 { await f.gate.close() }
        }
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await transport.download(request: request, session: session) }
        #expect(await f.store.calls == ["metadata"])
    }
    @Test func cancelWaitsForOwnedInsertAndKeepsFileAliveWithoutAcceptingReceipt() async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = "La copia exacta", request = try f.request(text)
        var asset: ChapterTextAsset? = try await ChapterTextAsset.create(.init(request: request, originalText: text, session: session), gate: f.gate, storageDirectory: f.storage)
        let barrier = SourceTransferBarrier(), done = SourceTransferCounter()
        await f.store.configure(nil, barrier: barrier)
        let transport = f.transport(session)
        let transfer = Task { [owned = asset!] in
            do {
                let result = try await transport.publish(owned, request: request, session: session)
                await done.finish(); return result
            } catch { await done.finish(); throw error }
        }
        asset = nil
        await barrier.wait(); transfer.cancel()
        let path = await f.store.heldFile
        #expect(FileManager.default.fileExists(atPath: try #require(path).path))
        #expect(await done.finished == false)
        await barrier.release()
        await #expect(throws: CancellationError.self) { try await transfer.value }
        #expect(await f.store.calls == ["metadata", "insert"])
        #expect(FileManager.default.fileExists(atPath: f.server.appendingPathComponent("source.utf8").path))
    }
    @Test func callbackCaptureSurvivesStagingRemovalBeforeOperationReturns() async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = "Antes\r\n🙂 e\u{301}", request = try f.request(text)
        await f.store.configure(try f.snapshot(text: text, request: request), captureThenDelete: true)
        let downloaded = try await f.transport(session).download(request: request, session: session)
        #expect(!FileManager.default.fileExists(atPath: f.incoming.path))
        #expect(Data(try await downloaded.asset.text(session: session, gate: f.gate).utf8) == Data(text.utf8))
        #expect(downloaded.receipt.evidence == .verifiedDownload)
    }
    @Test func callbackCopyCancellationRemovesOnlyPartialOwnedCopy() async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = String(repeating: "Cancela 🙂\n", count: 30_000), request = try f.request(text)
        let snapshot = try f.snapshot(text: text, request: request)
        let manifest = try JSONDecoder().decode(ChapterTextAssetManifest.self, from: snapshot.payload)
        let checks = Mutex(0)
        #expect(throws: CancellationError.self) {
            try ChapterTextAsset.captureDownloadedFile(download: f.incoming, manifest: manifest,
                request: request, session: session, storageDirectory: f.storage, check: {
                    let count = checks.withLock { $0 += 1; return $0 }
                    if count == 5 { throw CancellationError() }
                })
        }
        #expect(checks.withLock { $0 } == 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.incoming.path))
    }
    @Test func localAndCancellationErrorsStayOutOfTransportRetryClassification() {
        #expect(ChapterCloudTextTransport.classify(ChapterTextAssetError.invalidUTF8) as? ChapterSourceTransportError == .localFile(.invalidUTF8))
        #expect(ChapterCloudTextTransport.classify(ChapterTextAssetError.storage) as? ChapterSourceTransportError == .localFile(.storage))
        #expect(ChapterCloudTextTransport.classify(NSError(domain: NSPOSIXErrorDomain, code: 28)) as? ChapterSourceTransportError == .localIO)
        #expect(ChapterCloudTextTransport.classify(CancellationError()) is CancellationError)
    }
    @Test func permanentErrorDoesNotReconcileOrBlindRetry() async throws {
        let f = try CloudSourceFixture(), session = try await f.open(), text = "Hola", request = try f.request(text)
        await f.store.configure(nil, failure: .cloud(.retryAfter(seconds: 30)))
        let asset = try await ChapterTextAsset.create(.init(request: request, originalText: text, session: session), gate: f.gate, storageDirectory: f.storage)
        await #expect(throws: ChapterSourceTransportError.cloud(.retryAfter(seconds: 30))) {
            try await f.transport(session).publish(asset, request: request, session: session)
        }
        #expect(await f.store.calls == ["metadata", "insert"])
    }
}
