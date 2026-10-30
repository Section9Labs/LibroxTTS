import Foundation
import Testing
import AVFoundation
import CryptoKit
@testable import LibroxChapterWorker

private actor SegmentContentStore: ChapterCloudSegmentStore {
    let staging: URL
    var record: (key: String, manifest: Data, audio: Data)?
    var loseInsertAck = false
    var corruptDownload = false
    var inserts = 0
    var metadataFetches = 0
    var assetFetches = 0
    init(staging: URL) { self.staging = staging }
    func lostAck() { loseInsertAck = true }
    func corrupt() { corruptDownload = true }
    func replaceMetadata(_ data: Data) { if let record { self.record = (record.key, data, record.audio) } }
    func fetch(key: String, capture: ChapterCloudSegmentCapture?) async throws -> ChapterCloudSegmentSnapshot? {
        if capture == nil { metadataFetches += 1 } else { assetFetches += 1 }
        guard let record, record.key == key else { return nil }
        guard let capture else { return .init(key: key, tag: "server-tag-1", manifest: record.manifest, file: nil) }
        guard capture.expected.manifest == record.manifest, capture.expected.tag == "server-tag-1" else { throw ChapterCloudSegmentError.conflict }
        let url = staging.appendingPathComponent("wire-" + UUID().uuidString)
        var bytes = record.audio
        if corruptDownload { bytes[bytes.count - 1] ^= 1 }
        try bytes.write(to: url, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try ChapterCloudFileCapture.capture(download: url, expectedBytes: capture.manifest.audio.audioByteCount,
            expectedSHA256: capture.manifest.audio.audioSHA256, maximum: ChapterSegmentManifest.maximumBytes,
            session: capture.session, storageDirectory: capture.storage, check: { try Task.checkCancellation() })
        // Staging disappears before the caller receives its result. This seam
        // represents callback-scoped capture, not a live CloudKit operation.
        return .init(key: key, tag: "server-tag-1", manifest: record.manifest, file: file)
    }
    func insert(key: String, manifest: Data, audio: URL) async throws -> ChapterCloudSegmentSnapshot {
        inserts += 1
        guard record == nil else { throw ChapterDemandTransportError.conflict }
        record = (key, manifest, try Data(contentsOf: audio))
        if loseInsertAck { throw ChapterDemandTransportError.uncertain }
        return .init(key: key, tag: "server-tag-1", manifest: manifest, file: nil)
    }
}
private final class SegmentCloudFixture: Sendable {
    let root, captures, custody, incoming: URL
    let gate = ChapterAccountSessionGate()
    let store: SegmentContentStore
    let text = "A complete sentence."
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        captures = root.appendingPathComponent("captures"); custody = root.appendingPathComponent("custody")
        incoming = root.appendingPathComponent("incoming.wav")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: custody, withIntermediateDirectories: false)
        store = SegmentContentStore(staging: root)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2001)!
        buffer.frameLength = 2001
        for i in 0..<2001 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        let writer = try AVAudioFile(forWriting: incoming, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try writer.write(from: buffer)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func request(_ session: ChapterAccountSession) throws -> ChapterRenderRequest {
        try .init(accountPartition: session.accountPartition, source: .init(bookSHA256: String(repeating: "b", count: 64),
            chapterKey: "spine:2", textSHA256: ChapterCloudFileCapture.digest(Data(text.utf8)), extractionRevision: "test-1", utf16Length: text.utf16.count),
            recipe: .init(language: "en", stockVoiceID: "stock", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-inference", plannerRevision: "chapterV1",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-42", watermarkRevision: "disabled-1"))
    }
    func artifact(_ session: ChapterAccountSession) async throws -> ChapterLocalSegmentArtifact {
        let request = try request(session), bytes = try Data(contentsOf: incoming)
        let span = ChapterTextRange(offset: 0, length: text.utf16.count)
        let audio = ChapterArtifactManifest(renderKey: try request.renderKey(), audioSHA256: ChapterCloudFileCapture.digest(bytes),
            audioByteCount: Int64(bytes.count), decodedFrameCount: 2001, codecRevision: "wav-f32-1",
            units: [.init(source: span, fragments: [span], startFrame: 0, frameCount: 2001)])
        let manifest = try ChapterSegmentManifest(request: request, segmentIndex: 0, previousSegmentSHA256: nil,
            sourceRange: span, chapterStartFrame: 0, audio: audio, originalText: text)
        return try await .adopt(download: incoming, manifest: manifest, request: request, originalText: text,
            session: session, gate: gate, storageDirectory: custody)
    }
    func transport(_ session: ChapterAccountSession) -> ChapterCloudSegmentTransport {
        .init(store: store, session: session, gate: gate, captureStorage: captures, custodyStorage: custody)
    }
}
@Suite struct ChapterCloudSegmentTransportTests {
    @Test func lostUploadAckReconcilesActualBytesAndReaderUsesFreshPrivateCustody() async throws {
        let f = try SegmentCloudFixture(), session = try await f.gate.open(accountPartition: String(repeating: "a", count: 64))
        let artifact = try await f.artifact(session), transport = f.transport(session)
        await f.store.lostAck()
        let receipt = try await transport.upload(artifact, originalText: f.text)
        #expect(receipt.key == "s-" + (try artifact.manifest.sha256()))
        #expect(await f.store.inserts == 1); #expect(await f.store.assetFetches == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.captures.path).isEmpty)
        let fresh = try await f.gate.open(accountPartition: session.accountPartition)
        let download = try await f.transport(fresh).download(manifest: artifact.manifest, request: artifact.request, originalText: f.text)
        #expect(download.session == fresh); #expect(download.decodedPeak <= 1)
        try await download.withFileAccess(session: fresh, gate: f.gate) { url in
            let received = try Data(contentsOf: url), expected = try Data(contentsOf: f.incoming)
            #expect(received == expected)
        }
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await download.withFileAccess(session: session, gate: f.gate) { _ in true }
        }
        #expect(await f.store.inserts == 1)
    }
    @Test func metadataAdmissionPrecedesAssetFetchAndCorruptBytesNeverBecomeRetry() async throws {
        let f = try SegmentCloudFixture(), session = try await f.gate.open(accountPartition: String(repeating: "a", count: 64))
        let artifact = try await f.artifact(session), transport = f.transport(session)
        _ = try await transport.upload(artifact, originalText: f.text)
        await f.store.replaceMetadata(Data("{}".utf8))
        await #expect(throws: (any Error).self) {
            try await transport.download(manifest: artifact.manifest, request: artifact.request, originalText: f.text)
        }
        #expect(await f.store.assetFetches == 0)
        await f.store.replaceMetadata(try artifact.manifest.encoded()); await f.store.corrupt()
        await #expect(throws: ChapterCloudFileError.invalidFile) {
            try await transport.download(manifest: artifact.manifest, request: artifact.request, originalText: f.text)
        }
        #expect(await f.store.inserts == 1); #expect(await f.store.assetFetches == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.captures.path).isEmpty)
        #expect(try Data(contentsOf: f.incoming).count == Int(artifact.manifest.audio.audioByteCount))
    }
}
