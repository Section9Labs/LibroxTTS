import Foundation
import CryptoKit
import Synchronization
import XCTest
import KokoroCatalog
@testable import LibroxTTS

final class NarrationDownloads11Tests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fixture(_ root: URL, gzip: Bool = false) throws -> NarrationDownloadPlan {
        let raw = Data("hello world".utf8)
        let original: [String: Any] = ["path": "en/test.bin", "size": raw.count, "sha256": sha(raw), "sourceURL": "https://example.invalid/raw"]
        let manifest = try JSONDecoder().decode(AssetManifest.self, from: JSONSerialization.data(withJSONObject:
            ["repository": "fixture", "revision": "original", "files": [original], "installedFiles": [original]]))
        let chunks = gzip ? [Data(base64Encoded: "H4sIAAAAAAAC/8tIzcnJVwAA9vmB7QYAAAA=")!,
                             Data(base64Encoded: "H4sIAAAAAAAC/yvPL8pJAQBDEXc6BQAAAA==")!] : [raw]
        let parts = try chunks.enumerated().map { index, data -> NarrationDownloadPlan.Artifact in
            try data.write(to: root.appendingPathComponent("part-\(index)"))
            return .init(url: URL(string: "https://example.invalid/\(index)")!, size: Int64(data.count), sha256: sha(data),
                         decodedSize: gzip ? (index == 0 ? 6 : 5) : 11, encoding: gzip ? .gzip : .raw)
        }
        return .init(revision: "fixture", manifest: manifest, files: [.init(installed: manifest.files[0], artifacts: parts)])
    }
    func testIndependentGzipChunksReconstructAndReuseExactFile() throws {
        let source = try root(), dest = try root(), plan = try fixture(source, gzip: true)
        let urls = [source.appendingPathComponent("part-0"), source.appendingPathComponent("part-1")]
        try NarrationDownloads.install(plan.files[0], from: urls, in: dest)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("en/test.bin")), Data("hello world".utf8))
        try FileManager.default.removeItem(at: urls[0])
        try NarrationDownloads.install(plan.files[0], from: urls, in: dest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("en").path), ["test.bin"])
    }
    func testFullOutputBufferAtInputBoundaryNeedsMoreInputNotFailure() throws {
        // Valid gzip with FEXTRA padding and a sync-flush boundary: input byte
        // 65536 emits exactly 65536 bytes, but the final block arrives next read.
        var packed = Data(base64Encoded: "H4sIBAAAAAAA/6H/")!
        packed.append(Data(repeating: 0, count: 65441))
        packed.append(Data(base64Encoded: "7MEBAQAAAICQ/q/uCAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABqAAAA//8DAOuOl9cAAAEA")!)
        let directory = try root(), source = directory.appendingPathComponent("input.gz"), target = directory.appendingPathComponent("output")
        try packed.write(to: source)
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: nil))
        let output = try FileHandle(forWritingTo: target)
        try DownloadFileInstallation.append(source, encoding: .gzip, expectedSize: 65536, to: output)
        try output.close()
        XCTAssertEqual(try Data(contentsOf: target), Data(repeating: 0, count: 65536))
    }
    func testDecoderRejectsTruncationTrailingDataWrongLengthAndChecksumPreservingInstall() throws {
        for fault in 0..<5 {
            let source = try root(), dest = try root(), plan = try fixture(source, gzip: true)
            let target = dest.appendingPathComponent("en/test.bin")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old installed data".utf8).write(to: target)
            let url = source.appendingPathComponent("part-0")
            var bytes = try Data(contentsOf: url)
            if fault == 0 { bytes.removeLast() }
            if fault == 1 { bytes.append(0) }
            if fault == 2 { bytes.append(bytes) }
            if fault == 3 { bytes[bytes.count - 5] ^= 1 }
            try bytes.write(to: url)
            let old = plan.files[0].artifacts[0]
            let modified = NarrationDownloadPlan.Artifact(url: old.url, size: Int64(bytes.count), sha256: sha(bytes),
                decodedSize: fault == 4 ? 2 : old.decodedSize, encoding: .gzip)
            let file = NarrationDownloadPlan.File(installed: plan.files[0].installed, artifacts: [modified, plan.files[0].artifacts[1]])
            XCTAssertThrowsError(try NarrationDownloads.install(file, from: [url, source.appendingPathComponent("part-1")], in: dest))
            XCTAssertEqual(try Data(contentsOf: target), Data("old installed data".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path), ["test.bin"])
        }
    }
    func testPathsAndSymlinkParentsAreRejected() throws {
        for path in ["../outside", "/absolute", "a/../b", "a//b", "a/./b", "a\\b", ""] {
            XCTAssertThrowsError(try DownloadFileInstallation.validatePath(path))
        }
        let source = try root(), dest = try root(), outside = try root(), plan = try fixture(source)
        try FileManager.default.createSymbolicLink(at: dest.appendingPathComponent("en"), withDestinationURL: outside)
        XCTAssertThrowsError(try NarrationDownloads.install(plan.files[0], from: [source.appendingPathComponent("part-0")], in: dest))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    func testTransferRetainsCompletedChunkAcrossFailureThenSkipsInstalledFiles() async throws {
        let source = try root(), dest = try root(), cache = try root(), plan = try fixture(source, gzip: true)
        let calls = Mutex([String]()), shouldFail = Mutex(true), progress = Mutex([Double]())
        var transfer = NarrationTransport()
        transfer.fetch = { url, _ in
            calls.withLock { $0.append(url.lastPathComponent) }
            if url.lastPathComponent == "1", shouldFail.withLock({ $0 }) { throw URLError(.networkConnectionLost) }
            let temp = source.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source.appendingPathComponent("part-" + url.lastPathComponent), to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { try await transfer.run(plan, to: dest, cache: cache, concurrency: 3, progress: nil); XCTFail("Expected network failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        shouldFail.withLock { $0 = false }
        try await transfer.run(plan, to: dest, cache: cache, concurrency: 3, progress: { value in progress.withLock { $0.append(value) } })
        try await transfer.run(plan, to: dest, cache: cache, concurrency: 3, progress: nil)
        XCTAssertEqual(calls.withLock { $0 }, ["0", "1", "1"])
        let values = progress.withLock { $0 }; XCTAssertEqual(values.last, 1); XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("en/test.bin")), Data("hello world".utf8))
    }
    func testHTTPAndTransportCorruptionNeverReplaceInstalledFile() async throws {
        for status in [503, 200] {
            let source = try root(), dest = try root(), cache = try root(), plan = try fixture(source)
            let target = try DownloadFileInstallation.target("en/test.bin", in: dest)
            try Data("old".utf8).write(to: target)
            var transfer = NarrationTransport()
            transfer.fetch = { url, _ in
                let temp = source.appendingPathComponent(UUID().uuidString)
                try Data("wrong bytes".utf8).write(to: temp)
                return (temp, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do { try await transfer.run(plan, to: dest, cache: cache, concurrency: 1, progress: nil); XCTFail("Expected failure") }
            catch {}
            XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        }
    }
    func testCancellationDoesNotPublishOrStartFreshRetry() async throws {
        let source = try root(), dest = try root(), cache = try root(), plan = try fixture(source)
        let calls = Mutex(0)
        var transfer = NarrationTransport()
        transfer.fetch = { _, _ in
            calls.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        do { try await transfer.run(plan, to: dest, cache: cache, concurrency: 1, progress: nil); XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("en/test.bin").path))
    }
    func testStaleResumeFallsBackToFreshVerifiedTransfer() async throws {
        let source = try root(), dest = try root(), cache = try root(), plan = try fixture(source)
        let part = plan.files[0].artifacts[0], calls = Mutex([Bool]())
        try Data("stale".utf8).write(to: cache.appendingPathComponent(part.sha256 + ".resume"))
        var transfer = NarrationTransport()
        transfer.fetch = { url, resume in
            calls.withLock { $0.append(resume != nil) }
            if resume != nil { throw URLError(.cannotParseResponse) }
            let temp = source.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source.appendingPathComponent("part-0"), to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await transfer.run(plan, to: dest, cache: cache, concurrency: 1, progress: nil)
        XCTAssertEqual(calls.withLock { $0 }, [true, false])
    }
    func testCancellationRetainsOSResumeMetadata() async throws {
        let source = try root(), dest = try root(), cache = try root(), plan = try fixture(source)
        let resume = Data("opaque OS resume fixture".utf8)
        var transfer = NarrationTransport()
        transfer.fetch = { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue,
                userInfo: ["NSURLSessionDownloadTaskResumeData": resume])
        }
        do { try await transfer.run(plan, to: dest, cache: cache, concurrency: 1, progress: nil); XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let receipt = cache.appendingPathComponent(plan.files[0].artifacts[0].sha256 + ".resume")
        XCTAssertEqual(try Data(contentsOf: receipt), resume)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("en/test.bin").path))
    }
    func testRejectedHTTPResumeIsDiscardedBeforeNextRetry() async throws {
        let source = try root(), dest = try root(), cache = try root(), plan = try fixture(source)
        let receipt = cache.appendingPathComponent(plan.files[0].artifacts[0].sha256 + ".resume")
        try Data("expired redirect".utf8).write(to: receipt)
        let calls = Mutex([Bool]())
        var transfer = NarrationTransport()
        transfer.fetch = { url, resume in
            calls.withLock { $0.append(resume != nil) }
            let temporary = source.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source.appendingPathComponent("part-0"), to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: resume == nil ? 200 : 403, httpVersion: nil, headerFields: nil)!)
        }
        do { try await transfer.run(plan, to: dest, cache: cache, concurrency: 1, progress: nil); XCTFail("Expected rejection") }
        catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        try await transfer.run(plan, to: dest, cache: cache, concurrency: 1, progress: nil)
        XCTAssertEqual(calls.withLock { $0 }, [true, false])
    }
    func testUnknownManifestUsesOriginalTransport() throws {
        let source = try root(), original = try fixture(source)
        let plan = try NarrationDownloads.plan(for: original.manifest)
        XCTAssertEqual(plan.files[0].artifacts[0].encoding, .raw)
        XCTAssertEqual(plan.downloadSize, original.manifest.downloadSize)
        XCTAssertEqual(plan.files[0].installed.sha256, original.files[0].installed.sha256)
    }
    func testParallelFilesStayBoundedAndSharedContentIsSafe() async throws {
        let source = try root(), dest = try root(), cache = try root(), original = try fixture(source)
        let item = original.manifest.files[0]
        let rows = (0..<8).map { index -> [String: Any] in
            ["path": "en/\(index).bin", "size": item.size, "sha256": item.sha256, "sourceURL": "https://example.invalid/\(index)"]
        }
        let manifest = try JSONDecoder().decode(AssetManifest.self, from: JSONSerialization.data(withJSONObject:
            ["repository": "fixture", "revision": "original", "files": rows, "installedFiles": rows]))
        let plan = try NarrationDownloads.plan(for: manifest)
        let state = Mutex((active: 0, peak: 0))
        var transfer = NarrationTransport()
        transfer.fetch = { url, _ in
            state.withLock { $0.active += 1; $0.peak = max($0.peak, $0.active) }
            defer { state.withLock { $0.active -= 1 } }
            try await Task.sleep(for: .milliseconds(20))
            let temp = source.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source.appendingPathComponent("part-0"), to: temp)
            return (temp, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try await transfer.run(plan, to: dest, cache: cache, concurrency: 3, progress: nil)
        XCTAssertEqual(state.withLock { $0.peak }, 3)
        for file in manifest.files {
            XCTAssertTrue(try NarrationAssets.matches(dest.appendingPathComponent(file.path), size: file.size, sha256: file.sha256))
        }
    }
    /// Qualification against every published transport artifact, not run in ordinary CI.
    func testReconstructCompleteCatalogFromReleaseArtifacts() throws {
        let env = ProcessInfo.processInfo.environment
        guard let work = env["LIBROX_11_ARTIFACTS"], let catalogs = env["LIBROX_11_CATALOG"],
              let output = env["LIBROX_11_OUTPUT"] else { throw XCTSkip("Opt-in complete transport reconstruction") }
        let root = URL(fileURLWithPath: output)
        var count = 0
        for url in try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: catalogs), includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            let manifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: url))
            let plan = try NarrationDownloads.plan(for: manifest)
            for file in plan.files where file.artifacts.first?.encoding == .gzip {
                let artifacts = file.artifacts.map { URL(fileURLWithPath: work).appendingPathComponent($0.sha256 + ".gz") }
                try NarrationDownloads.install(file, from: artifacts, in: root)
                XCTAssertTrue(try NarrationAssets.matches(root.appendingPathComponent(file.installed.path),
                    size: file.installed.size, sha256: file.installed.sha256))
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 500)
        print("TRANSPORT_RECONSTRUCTED_FILES=\(count)")
    }
    /// Real URLSession/GitHub qualification. The caller owns persistent output/cache.
    func testHostedEnglishDownloadAndNoDownloadReuse() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["LIBROX_11_LIVE_OUTPUT"], let catalogs = env["LIBROX_11_CATALOG"] else {
            throw XCTSkip("Opt-in hosted English transport qualification")
        }
        let root = URL(fileURLWithPath: output), cache = root.appendingPathComponent("transfer-cache")
        var totals: Int64 = 0
        for name in ["en.json", "coreml-en.json", "delivery-en.json"] {
            let manifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf:
                URL(fileURLWithPath: catalogs).appendingPathComponent(name)))
            let plan = try NarrationDownloads.plan(for: manifest)
            let started = ProcessInfo.processInfo.systemUptime
            try await NarrationDownloads.download(plan, to: root, cache: cache)
            print("HOSTED_PLAN=\(name) WIRE_BYTES=\(plan.downloadSize) SECONDS=\(ProcessInfo.processInfo.systemUptime-started)")
            var noNetwork = NarrationTransport()
            noNetwork.fetch = { _, _ in throw URLError(.notConnectedToInternet) }
            try await noNetwork.run(plan, to: root, cache: cache, concurrency: 3, progress: nil)
            for file in manifest.installedFiles {
                XCTAssertTrue(try NarrationAssets.matches(root.appendingPathComponent(file.path), size: file.size, sha256: file.sha256))
            }
            totals += plan.downloadSize
        }
        print("HOSTED_VERIFIED_TOTAL_BYTES=\(totals)")
    }
}
