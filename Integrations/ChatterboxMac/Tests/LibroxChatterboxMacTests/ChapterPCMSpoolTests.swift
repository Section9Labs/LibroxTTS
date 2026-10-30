#if os(macOS)
import XCTest
import Foundation
import CryptoKit
@testable import LibroxChatterbox
@testable import LibroxChatterboxMac

final class ChapterPCMSpoolTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    func testExactGlobalSourceAndPostCadenceFrameMapsWithUnicode() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = "  Cafe\u{301} 🐈.\n\u{FFFC} Hola.  ", original = source as NSString
        let first = original.range(of: "Cafe\u{301} 🐈."), second = original.range(of: "Hola.")
        let spool = try ChapterPCMSpool(source: source, directory: dir), generation = UUID()
        let a: [Float] = [0, 0.25, -0.5, 0], b: [Float] = [0, 0.7, 0]
        try await spool.append(index: 0, generation: generation, range: first, text: original.substring(with: first), fragments: [first], samples: a)
        try await spool.append(index: 1, generation: generation, range: second, text: "Hola.", fragments: [second], samples: b)
        let result = try await spool.finish()
        XCTAssertEqual(result.frames, 7); XCTAssertEqual(result.units.map(\.startFrame), [0, 4])
        XCTAssertEqual(result.units.map(\.frameCount), [4, 3]); XCTAssertEqual(result.units[1].source.offset, second.location)
        let data = try Data(contentsOf: result.file)
        XCTAssertEqual(data.count, 28)
        let expected = (a + b).map { $0.bitPattern.littleEndian }.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(data, expected)
        XCTAssertEqual(result.pcmSHA256, SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
        do { _ = try await spool.finish(); XCTFail("must not finalize twice") } catch { XCTAssertEqual(error as? ChatterboxMacRendererError, .closed) }
    }
    func testOmittedWordsAndWrongGenerationRejectAndPoisonSpool() async throws {
        for skip in [true, false] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let spool = try ChapterPCMSpool(source: "One. Two.", directory: dir), generation = UUID()
            try await spool.append(index: 0, generation: generation, range: NSRange(location: 0, length: 4), text: "One.", fragments: [NSRange(location: 0, length: 4)], samples: [0.1])
            do {
                if skip { _ = try await spool.finish() }
                else { try await spool.append(index: 1, generation: UUID(), range: NSRange(location: 5, length: 4), text: "Two.", fragments: [NSRange(location: 5, length: 4)], samples: [0.1]) }
                XCTFail("must reject")
            } catch {}
            do { _ = try await spool.finish(); XCTFail("failed spool cannot be accepted") } catch {}
        }
    }
    func testGraphemeFragmentAndInvalidAudioRejection() async throws {
        for mode in 0..<4 {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let spool = try ChapterPCMSpool(source: "e\u{301} words", directory: dir)
            do {
                try await spool.append(index: 0, generation: UUID(), range: NSRange(location: 0, length: mode == 0 ? 1 : 8),
                    text: mode == 0 ? "e" : "e\u{301} words",
                    fragments: [NSRange(location: mode == 1 ? 3 : 0, length: mode == 1 ? 5 : (mode == 0 ? 1 : 8))],
                    samples: [mode == 2 ? .nan : (mode == 3 ? 1.01 : 0.1)])
                XCTFail("must reject")
            } catch {}
            do { _ = try await spool.finish(); XCTFail("must not accept") } catch {}
        }
    }
    func testMismatchedModelRequestAndSourceContextPoisonSpool() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = "Original.", voice = dir.appendingPathComponent("unused-synthetic.safetensors")
        let unit = try XCTUnwrap(ChatterboxBookDirector.plan(source, language: "en", narratorID: "stock", conditioningFiles: ["stock": voice]).first)
        let rewritten = try ChatterboxRequest(text: "Altered.", language: "en", conditioningFile: voice, sourceContext: unit.request.sourceContext)
        let badUnit = ChatterboxDirectedUnit(request: rewritten, timingContext: unit.timingContext,
            performance: unit.performance, sourceFragments: unit.sourceFragments)
        let generation = UUID(), spool = try ChapterPCMSpool(source: source, directory: dir)
        let bad = ChatterboxPreparedPassage(index: 0, unit: badUnit, samples: [0.1], cacheHit: false,
            timings: nil, generatedFrames: 1, generationID: generation)
        do { try await spool.append(bad); XCTFail("rewritten model input must reject") } catch { XCTAssertEqual(error as? ChatterboxMacRendererError, .invalidPassage) }
        let correct = ChatterboxPreparedPassage(index: 0, unit: unit, samples: [0.1], cacheHit: false,
            timings: nil, generatedFrames: 1, generationID: generation)
        do { try await spool.append(correct); XCTFail("poisoned spool must not resume") } catch { XCTAssertEqual(error as? ChatterboxMacRendererError, .closed) }
    }
}
#endif
