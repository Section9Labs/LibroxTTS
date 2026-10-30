import Foundation
import Testing
import CryptoKit
import Darwin
@testable import LibroxChapterWorker

@Suite struct ChapterCloudFileCaptureTests {
    @Test func privateCaptureSurvivesStagingRemovalAndPreservesUnknownFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("stage"), storage = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        let data = Data(repeating: 23, count: 131073), hash = ChapterCloudFileCapture.digest(data)
        try data.write(to: input)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        var capture: ChapterCloudFileCapture? = try .capture(download: input, expectedBytes: Int64(data.count),
            expectedSHA256: hash, maximum: 200000, session: session, storageDirectory: storage, check: {})
        try FileManager.default.removeItem(at: input)
        let url = try await #require(capture).withFileAccess(session: session, gate: gate) { url in
            #expect(try Data(contentsOf: url) == data)
            let unknown = url.deletingLastPathComponent().appendingPathComponent("unknown")
            try Data("keep".utf8).write(to: unknown)
            return url
        }
        capture = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("unknown"), encoding: .utf8) == "keep")
    }
    @Test func rejectsHashSymlinkFIFOAndMidCopyCancellationWithoutTouchingInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("stage"), storage = root.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        let data = Data(repeating: 23, count: 131073), hash = ChapterCloudFileCapture.digest(data)
        try data.write(to: input)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let symbolic = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: input)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for url in [symbolic, fifo] {
            #expect(throws: ChapterCloudFileError.invalidFile) {
                try ChapterCloudFileCapture.capture(download: url, expectedBytes: Int64(data.count), expectedSHA256: hash,
                    maximum: 200000, session: session, storageDirectory: storage, check: {})
            }
        }
        #expect(throws: ChapterCloudFileError.invalidFile) {
            try ChapterCloudFileCapture.capture(download: input, expectedBytes: Int64(data.count), expectedSHA256: String(repeating: "0", count: 64),
                maximum: 200000, session: session, storageDirectory: storage, check: {})
        }
        var calls = 0
        #expect(throws: CancellationError.self) {
            try ChapterCloudFileCapture.capture(download: input, expectedBytes: Int64(data.count), expectedSHA256: hash,
                maximum: 200000, session: session, storageDirectory: storage, check: {
                    calls += 1; if calls == 4 { throw CancellationError() }
                })
        }
        #expect(try Data(contentsOf: input) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
    }
}
