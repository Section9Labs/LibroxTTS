import Foundation
import Testing
import CryptoKit
import AVFoundation
import AudioToolbox
@testable import LibroxChapterWorker

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func wav(_ samples: [Float], sampleRate: UInt32 = 24_000) -> Data {
    var data = Data()
    func bytes<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    data.append(Data("RIFF".utf8)); bytes(UInt32(36 + samples.count * 4))
    data.append(Data("WAVEfmt ".utf8)); bytes(UInt32(16)); bytes(UInt16(3)); bytes(UInt16(1))
    bytes(sampleRate); bytes(sampleRate * 4); bytes(UInt16(4)); bytes(UInt16(32))
    data.append(Data("data".utf8)); bytes(UInt32(samples.count * 4))
    for sample in samples { bytes(sample.bitPattern) }
    return data
}

private final class LocalFixture: Sendable {
    let root: URL
    let storage: URL
    let incoming: URL
    let gate = ChapterAccountSessionGate()
    let text = "A🙂B"
    init(data: Data) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = root.appendingPathComponent("owned")
        incoming = root.appendingPathComponent("download.wav")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try data.write(to: incoming)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func request(watermark: String = "disabled-1") throws -> ChapterRenderRequest {
        try .init(accountPartition: String(repeating: "a", count: 64), source: .init(
            bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:0", textSHA256: digest(Data(text.utf8)),
            extractionRevision: "reader-1", utf16Length: text.utf16.count), recipe: .init(
                language: "en", stockVoiceID: "stock", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "standard", plannerRevision: "chapter-1",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-1", watermarkRevision: watermark))
    }
    func manifest(_ request: ChapterRenderRequest, frames: Int64 = 4, codec: String = "wav-f32-1",
                  hash: String? = nil, span: ChapterTextRange? = nil) throws -> ChapterArtifactManifest {
        let bytes = try Data(contentsOf: incoming)
        let range = span ?? .init(offset: 0, length: text.utf16.count)
        return .init(renderKey: try request.renderKey(), audioSHA256: hash ?? digest(bytes), audioByteCount: Int64(bytes.count),
                     decodedFrameCount: frames, codecRevision: codec,
                     units: [.init(source: range, fragments: [range], startFrame: 0, frameCount: frames)])
    }
    func session() async throws -> ChapterAccountSession { try await gate.open(accountPartition: String(repeating: "a", count: 64)) }
    func adopt(_ request: ChapterRenderRequest, _ manifest: ChapterArtifactManifest, _ session: ChapterAccountSession,
               text: String? = nil, download: URL? = nil) async throws -> ChapterLocalArtifact {
        try await .adopt(download: download ?? incoming, request: request, manifest: manifest, originalText: text ?? self.text,
                         session: session, gate: gate, storageDirectory: storage)
    }
    var ownedChildren: [URL] { (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [] }
}

@Suite(.serialized) struct ChapterLocalArtifactTests {
    @Test func validWAVOwnsIndependentReadOnlyCopyAndCleansOnlyOwnedFiles() async throws {
        let f = try LocalFixture(data: wav([0, 0.25, -0.5, 1]))
        let request = try f.request(), manifest = try f.manifest(request), session = try await f.session()
        var asset: ChapterLocalArtifact? = try await f.adopt(request, manifest, session)
        #expect(asset?.decodedFrameCount == 4)
        #expect(asset?.decodedPeak == 1)
        let originalBytes = try Data(contentsOf: f.incoming)
        try Data("changed download".utf8).write(to: f.incoming)
        let owned = try await #require(asset).withFileAccess(session: session, gate: f.gate) { url in
            #expect(try Data(contentsOf: url) == originalBytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
            return url
        }
        #expect(FileManager.default.fileExists(atPath: owned.path))
        asset = nil
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(FileManager.default.fileExists(atPath: f.incoming.path))
        #expect(f.ownedChildren.isEmpty)
    }

    @Test func alac24IsActuallyDecoded() async throws {
        let f = try LocalFixture(data: Data())
        let output = f.root.appendingPathComponent("encoded.m4a")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_001))
        buffer.frameLength = 144_001
        for index in 0..<144_001 { buffer.floatChannelData![0][index] = index.isMultiple(of: 2) ? 0.25 : -0.125 }
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 24],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        try Data(contentsOf: output).write(to: f.incoming)
        let request = try f.request(), session = try await f.session()
        let asset = try await f.adopt(request, f.manifest(request, frames: 144_001, codec: "alac24-1"), session)
        #expect(asset.codec == .alac24)
        #expect(asset.decodedFrameCount == 144_001)
        #expect(asset.decodedPeak == 0.25)
    }

    @Test func nonPacketAlignedWAVSpansMultipleDecodeBuffers() async throws {
        let f = try LocalFixture(data: wav(Array(repeating: 0.125, count: 144_001)))
        let request = try f.request(), session = try await f.session()
        let asset = try await f.adopt(request, f.manifest(request, frames: 144_001), session)
        #expect(asset.decodedFrameCount == 144_001)
        #expect(asset.decodedPeak == 0.125)
    }

    @Test func invalidSamplesAreRejectedWithoutNormalization() async throws {
        for sample in [Float.nan, Float.infinity, -Float.infinity, Float(1.01), Float(-1.01)] {
            let f = try LocalFixture(data: wav([0, sample, 0, 0]))
            let request = try f.request(), manifest = try f.manifest(request), session = try await f.session()
            await #expect(throws: ChapterLocalArtifactError.invalidSamples) { try await f.adopt(request, manifest, session) }
            #expect(f.ownedChildren.isEmpty)
        }
    }

    @Test func hashFrameRateCodecAndPolicyMismatchesFailClosed() async throws {
        let f = try LocalFixture(data: wav([0, 0.25, 0, 0]))
        let request = try f.request(), session = try await f.session()
        await #expect(throws: ChapterLocalArtifactError.invalidFile) {
            try await f.adopt(request, f.manifest(request, hash: String(repeating: "0", count: 64)), session)
        }
        await #expect(throws: ChapterLocalArtifactError.invalidFrames) { try await f.adopt(request, f.manifest(request, frames: 5), session) }
        await #expect(throws: ChapterLocalArtifactError.invalidFormat) {
            try await f.adopt(request, f.manifest(request, codec: "alac24-1"), session)
        }
        let marked = try f.request(watermark: "perth-1")
        await #expect(throws: ChapterLocalArtifactError.unsupportedPolicy) { try await f.adopt(marked, f.manifest(marked), session) }
        try wav([0, 0, 0, 0], sampleRate: 48_000).write(to: f.incoming)
        await #expect(throws: ChapterLocalArtifactError.invalidFormat) { try await f.adopt(request, f.manifest(request), session) }
        #expect(f.ownedChildren.isEmpty)
    }

    @Test func exactSourceAndSurrogateBoundariesAreRequired() async throws {
        let f = try LocalFixture(data: wav([0, 0, 0, 0]))
        let request = try f.request(), session = try await f.session()
        await #expect(throws: ChapterWorkerError.invalidIdentity) {
            try await f.adopt(request, f.manifest(request), session, text: "Different text")
        }
        await #expect(throws: ChapterWorkerError.invalidManifest) {
            try await f.adopt(request, f.manifest(request, span: .init(offset: 1, length: 1)), session)
        }
        #expect(f.ownedChildren.isEmpty)
    }

    @Test func staleAccountAndCancelledAdoptionCannotReturnAHandle() async throws {
        let f = try LocalFixture(data: wav([0, 0, 0, 0]))
        let request = try f.request(), manifest = try f.manifest(request), old = try await f.session()
        let new = try await f.session()
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await f.adopt(request, manifest, old) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.adopt(request, manifest, new)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(f.ownedChildren.isEmpty)
    }

    @Test func accountChangeDuringFileAccessRejectsLateResult() async throws {
        let f = try LocalFixture(data: wav([0, 0, 0, 0]))
        let request = try f.request(), session = try await f.session()
        let asset = try await f.adopt(request, f.manifest(request), session)
        let gate = f.gate
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await asset.withFileAccess(session: session, gate: gate) { _ in
                await gate.close()
                return true
            }
        }
    }

    @Test func symlinksAndOversizedDecodedBudgetsAreRejected() async throws {
        let f = try LocalFixture(data: wav([0, 0, 0, 0]))
        let request = try f.request(), session = try await f.session()
        let link = f.root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.incoming)
        await #expect(throws: ChapterLocalArtifactError.invalidFile) { try await f.adopt(request, f.manifest(request), session, download: link) }
        await #expect(throws: ChapterLocalArtifactError.budgetExceeded) {
            try await f.adopt(request, f.manifest(request, frames: ChapterLocalArtifact.maximumDecodedFrames + 1), session)
        }
        #expect(f.ownedChildren.isEmpty)
    }
}
