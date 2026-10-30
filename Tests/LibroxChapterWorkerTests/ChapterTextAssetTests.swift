import Foundation
import Testing
import CryptoKit
import Darwin
@testable import LibroxChapterWorker

private func textDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private final class TextFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage: URL
    let incoming: URL
    let gate = ChapterAccountSessionGate()
    init() throws {
        storage = root.appendingPathComponent("owned"); incoming = root.appendingPathComponent("incoming.utf8")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func request(_ data: Data, length: Int, partition: String = String(repeating: "a", count: 64),
                 delivery: ChapterAudioDelivery = .lossless) throws -> ChapterRenderRequest {
        try .init(accountPartition: partition, source: .init(bookSHA256: String(repeating: "b", count: 64),
            chapterKey: "spine:7", textSHA256: textDigest(data), extractionRevision: "exact-1", utf16Length: length),
            recipe: .init(language: "es", stockVoiceID: "stock", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "standard", plannerRevision: "chapter-1",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-42", watermarkRevision: "disabled-1"), delivery: delivery)
    }
    func submission(_ text: String, session: ChapterAccountSession) throws -> ChapterSubmission {
        try .init(request: request(Data(text.utf8), length: text.utf16.count), originalText: text, session: session)
    }
    func session() async throws -> ChapterAccountSession { try await gate.open(accountPartition: String(repeating: "a", count: 64)) }
    var children: [URL] { (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [] }
}

@Suite(.serialized) struct ChapterTextAssetTests {
    @Test func exactUnicodeAndLargeChapterBytesSurvivePrivateCopy() async throws {
        let f = try TextFixture(), session = try await f.session()
        let text = String(repeating: "A\r\ne\u{301}🙂\u{fffc}終\n", count: 12_000)
        let bytes = Data(text.utf8), submission = try f.submission(text, session: session)
        #expect(bytes.count > 65_536)
        let asset = try await ChapterTextAsset.create(submission, gate: f.gate, storageDirectory: f.storage)
        #expect(asset.manifest.byteCount == bytes.count)
        #expect(Data(try await asset.text(session: session, gate: f.gate).utf8) == bytes)
        try await asset.withFileAccess(session: session, gate: f.gate) { url in
            let stored = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(stored == bytes)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
        }
        let roundTrip = try JSONDecoder().decode(ChapterTextAssetManifest.self, from: JSONEncoder().encode(asset.manifest))
        try roundTrip.validate(for: submission.request)
    }

    @Test func sourceIdentityIndependentOfDeliveryAndAccountButManifestPartitionIsNot() throws {
        let f = try TextFixture(), data = Data("e\u{301}🙂".utf8)
        let a = try f.request(data, length: 4), b = try f.request(data, length: 4, delivery: .smaller)
        let x = try f.request(data, length: 4, partition: String(repeating: "1", count: 64))
        let m = try ChapterTextAssetManifest(request: a, byteCount: data.count)
        #expect(try m.sourceKey() == ChapterTextAssetManifest(request: b, byteCount: data.count).sourceKey())
        #expect(try m.sourceKey() == ChapterTextAssetManifest(request: x, byteCount: data.count).sourceKey())
        #expect(throws: ChapterTextAssetError.invalidManifest) { try m.validate(for: x) }
        let normalized = Data("é🙂".utf8), r = try f.request(normalized, length: 3)
        #expect(try m.sourceKey() != ChapterTextAssetManifest(request: r, byteCount: normalized.count).sourceKey())
    }

    @Test func downloadedCopyIsIndependentAndReleasesOnlyItsOwnFile() async throws {
        let f = try TextFixture(), session = try await f.session(), text = "Hola\r\n🙂"
        let data = Data(text.utf8), request = try f.request(data, length: text.utf16.count)
        try data.write(to: f.incoming)
        let manifest = try ChapterTextAssetManifest(request: request, byteCount: data.count)
        var asset: ChapterTextAsset? = try await .adopt(download: f.incoming, manifest: manifest, request: request,
            session: session, gate: f.gate, storageDirectory: f.storage)
        let url = try await #require(asset).withFileAccess(session: session, gate: f.gate) { $0 }
        try Data("changed incoming".utf8).write(to: f.incoming)
        #expect(Data(try await #require(asset).text(session: session, gate: f.gate).utf8) == data)
        let unrelated = url.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: unrelated)
        asset = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: unrelated) == Data("preserve".utf8))
        #expect(try Data(contentsOf: f.incoming) == Data("changed incoming".utf8))
    }

    @Test func malformedHeadersCannotMakeSourceKeys() throws {
        let f = try TextFixture(), request = try f.request(Data("abc".utf8), length: 3)
        let manifest = try ChapterTextAssetManifest(request: request, byteCount: 3)
        for (key, value) in [("version", 2 as Any), ("accountPartition", "invalid" as Any),
                             ("byteCount", -1 as Any), ("byteCount", 2 as Any), ("byteCount", 10 as Any),
                             ("utf8SHA256", String(repeating: "0", count: 64) as Any)] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
            object[key] = value
            let decoded = try JSONDecoder().decode(ChapterTextAssetManifest.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: ChapterTextAssetError.invalidManifest) { try decoded.validate(for: request) }
            #expect(throws: ChapterTextAssetError.invalidManifest) { try decoded.sourceKey() }
        }
    }

    @Test func corruptedInvalidUTF8AndWrongLengthDownloadsFailWithoutDeletingInput() async throws {
        let f = try TextFixture(), session = try await f.session()
        let cases: [(Data, Data, Int)] = [(Data("abc".utf8), Data("abd".utf8), 3),
            (Data([0x61, 0xc0, 0xaf]), Data([0x61, 0xc0, 0xaf]), 3),
            (Data("é".utf8), Data("é".utf8), 2)]
        for (expected, received, length) in cases {
            let request = try f.request(expected, length: length)
            let manifest = try ChapterTextAssetManifest(request: request, byteCount: expected.count)
            try received.write(to: f.incoming)
            await #expect(throws: ChapterTextAssetError.invalidUTF8) {
                try await ChapterTextAsset.adopt(download: f.incoming, manifest: manifest, request: request,
                    session: session, gate: f.gate, storageDirectory: f.storage)
            }
            #expect(try Data(contentsOf: f.incoming) == received)
            #expect(f.children.isEmpty)
        }
    }

    @Test func sourceAndStorageSymlinksAndFIFOsAreRejected() async throws {
        let f = try TextFixture(), session = try await f.session(), data = Data("abc".utf8)
        let request = try f.request(data, length: 3), manifest = try ChapterTextAssetManifest(request: request, byteCount: data.count)
        let original = f.root.appendingPathComponent("original.txt"); try data.write(to: original)
        try FileManager.default.createSymbolicLink(at: f.incoming, withDestinationURL: original)
        await #expect(throws: ChapterTextAssetError.invalidFile) {
            try await ChapterTextAsset.adopt(download: f.incoming, manifest: manifest, request: request,
                session: session, gate: f.gate, storageDirectory: f.storage)
        }
        try FileManager.default.removeItem(at: f.incoming)
        #expect(mkfifo(f.incoming.path, mode_t(0o600)) == 0)
        await #expect(throws: ChapterTextAssetError.invalidFile) {
            try await ChapterTextAsset.adopt(download: f.incoming, manifest: manifest, request: request,
                session: session, gate: f.gate, storageDirectory: f.storage)
        }
        let link = f.root.appendingPathComponent("storage-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.storage)
        await #expect(throws: ChapterTextAssetError.storage) {
            try await ChapterTextAsset.create(f.submission("abc", session: session), gate: f.gate, storageDirectory: link)
        }
        #expect(try Data(contentsOf: original) == data)
        #expect(f.children.isEmpty)
    }

    @Test func staleAndCancelledOperationsDoNotReturnCustody() async throws {
        let f = try TextFixture(), old = try await f.session(), submission = try f.submission("abc", session: old)
        _ = try await f.session()
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterTextAsset.create(submission, gate: f.gate, storageDirectory: f.storage)
        }
        let current = try await f.session(), valid = try f.submission("abc", session: current)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ChapterTextAsset.create(valid, gate: f.gate, storageDirectory: f.storage)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(f.children.isEmpty)
        let asset = try await ChapterTextAsset.create(valid, gate: f.gate, storageDirectory: f.storage)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await asset.withFileAccess(session: current, gate: f.gate) { _ in await f.gate.close(); return true }
        }
    }

    @Test func mutationOrPathReplacementDuringScopedAccessCannotReturnSuccess() async throws {
        let f = try TextFixture(), session = try await f.session()
        let asset = try await ChapterTextAsset.create(f.submission("abc", session: session), gate: f.gate, storageDirectory: f.storage)
        await #expect(throws: ChapterTextAssetError.invalidUTF8) {
            try await asset.withFileAccess(session: session, gate: f.gate) { url in
                #expect(chmod(url.path, mode_t(0o600)) == 0)
                let writer = try FileHandle(forWritingTo: url); try writer.write(contentsOf: Data("abd".utf8)); try writer.close()
                return true
            }
        }
        var second: ChapterTextAsset? = try await .create(f.submission("abc", session: session), gate: f.gate, storageDirectory: f.storage)
        let moved = f.root.appendingPathComponent("moved")
        let replacement = try await #require(second).withFileAccess(session: session, gate: f.gate) { $0 }
        await #expect(throws: ChapterTextAssetError.invalidFile) {
            try await #require(second).withFileAccess(session: session, gate: f.gate) { url in
                try FileManager.default.moveItem(at: url.deletingLastPathComponent(), to: moved)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false)
                try Data("abc".utf8).write(to: url)
                return true
            }
        }
        second = nil
        #expect(try Data(contentsOf: replacement) == Data("abc".utf8))
    }
    @Test func stagedCreationFailuresCleanOnlyBoundOwnedResources() async throws {
        enum Forced: Error { case storage }
        let f = try TextFixture(), session = try await f.session(), bytes = Data("abc".utf8)
        let request = try f.request(bytes, length: 3), manifest = try ChapterTextAssetManifest(request: request, byteCount: 3)
        for point in ChapterTextAsset.CreationBoundary.allCases {
            #expect(throws: Forced.storage) {
                try ChapterTextAsset.build(manifest: manifest, session: session, storage: f.storage,
                    boundary: { if $0 == point { throw Forced.storage } },
                    write: { _ in Issue.record("write must not start after a creation failure") })
            }
            #expect(f.children.isEmpty)
        }
        // Cancellation after real bytes were written must clean up before the
        // detached writer is joined; no accepted custody can escape the failure.
        let worker = Task.detached {
            try ChapterTextAsset.build(manifest: manifest, session: session, storage: f.storage) { output in
                try output.write(contentsOf: bytes)
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(f.children.isEmpty)
    }

}
