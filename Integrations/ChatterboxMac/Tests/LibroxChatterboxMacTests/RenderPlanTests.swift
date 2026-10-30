#if os(macOS)
import Foundation
import XCTest
import LibroxChatterbox
import LibroxChapterWorker
@testable import LibroxChatterboxMac

private struct PlanTestBackend: ResidentChapterBackend {
    let profile: String
    let modelSHA256 = String(repeating: "b", count: 64)
    let conditioningSHA256 = String(repeating: "c", count: 64)
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL,
                receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        throw ChatterboxMacRendererError.unavailable // No rendering in these tests.
    }
}

final class RenderPlanTests: XCTestCase {
    private let source = "Cafe\u{301} 🐈.\r\n¡Sigue adelante!"
    private func request() throws -> ChatterboxMacChapterRequest {
        let original = source as NSString
        let first = original.range(of: "Cafe\u{301} 🐈."), second = original.range(of: "¡Sigue adelante!")
        let directions = try ChatterboxPerformanceDirections(source: source, annotations: [
            .init(range: first, originalText: original.substring(with: first), performance: .init(delivery: .soft, strength: .subtle),
                controls: .init(exaggeration: Float(bitPattern: 0x80000000), guidance: 0.3, temperature: 0.8)),
            .init(range: second, originalText: original.substring(with: second), performance: .init(delivery: .urgent, strength: .strong),
                controls: .init(exaggeration: Float(bitPattern: 0x3f666667), guidance: 0.25, temperature: Float(bitPattern: 0x3f4ccccd)))
        ], scope: .chapterV1)
        return try .init(text: source, language: "es", delivery: .smaller, direction: .storyteller,
            grouping: .compatibleNarration(maxCharacters: 160), performanceDirections: directions, seed: .max)
    }
    private func json(_ data: Data, change: (inout [String: Any]) throws -> Void) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try change(&value)
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    func testExactExpressionsAndScalarBitsSurviveCanonicalRoundTrip() throws {
        let original = try request(), plan = try ChatterboxMacRenderPlan(request: original)
        let decoded = try ChatterboxMacRenderPlan.decode(plan.encoded(), source: source)
        let restored = try decoded.restore(source: source)
        XCTAssertEqual(plan.sha256, decoded.sha256); XCTAssertEqual(plan.encoded(), decoded.encoded())
        XCTAssertEqual(restored.seed, .max); XCTAssertEqual(restored.delivery, .smaller)
        XCTAssertEqual(restored.grouping, .compatibleNarration(maxCharacters: 160))
        XCTAssertEqual(restored.direction, .storyteller)
        XCTAssertEqual(try restored.expressionIdentity(), try original.expressionIdentity())
        XCTAssertEqual(try restored.synthesisIdentity(rendererProfile: "synthetic"), try original.synthesisIdentity(rendererProfile: "synthetic"))
        let left = try XCTUnwrap(original.performanceDirections).annotations
        let right = try XCTUnwrap(restored.performanceDirections).annotations
        XCTAssertEqual(left.count, right.count)
        for (a, b) in zip(left, right) {
            XCTAssertEqual(a.range, b.range); XCTAssertEqual(Data(a.originalText.utf8), Data(b.originalText.utf8))
            XCTAssertEqual(a.performance, b.performance)
            XCTAssertEqual(a.controls?.exaggeration.bitPattern, b.controls?.exaggeration.bitPattern)
            XCTAssertEqual(a.controls?.guidance.bitPattern, b.controls?.guidance.bitPattern)
            XCTAssertEqual(a.controls?.temperature.bitPattern, b.controls?.temperature.bitPattern)
        }
    }
    func testAbsentAndAuthoredEmptyDirectionsPreserveTheirShape() throws {
        for authored in [false, true] {
            let directions = authored ? try ChatterboxPerformanceDirections(source: source, annotations: [], scope: .chapterV1) : nil
            let original = try ChatterboxMacChapterRequest(text: source, language: "en", delivery: .lossless,
                direction: .neutral, grouping: .sentences, performanceDirections: directions, seed: 7)
            let plan = try ChatterboxMacRenderPlan(request: original)
            let restored = try ChatterboxMacRenderPlan.decode(plan.encoded(), source: source).restore(source: source)
            XCTAssertEqual(restored.performanceDirections != nil, authored)
            XCTAssertEqual(restored.direction, .neutral); XCTAssertEqual(restored.grouping, .sentences)
            XCTAssertEqual(restored.delivery, .lossless); XCTAssertEqual(restored.seed, 7)
        }
    }
    func testStaleSourceUnknownOptionsAndNoncanonicalFieldsReject() throws {
        let bytes = try ChatterboxMacRenderPlan(request: request()).encoded()
        XCTAssertThrowsError(try ChatterboxMacRenderPlan.decode(bytes, source: source.precomposedStringWithCanonicalMapping)) {
            XCTAssertEqual($0 as? ChatterboxMacRenderPlanError, .sourceMismatch)
        }
        for (key, value) in [("version", 99 as Any), ("direction", "unknown" as Any), ("grouping", "faster" as Any),
                             ("maximumCharacters", 301 as Any), ("expressionSHA256", String(repeating: "0", count: 64) as Any),
                             ("unexpectedFallback", true as Any)] {
            let mutated = try json(bytes) { $0[key] = value }
            XCTAssertThrowsError(try ChatterboxMacRenderPlan.decode(mutated, source: source))
        }
        XCTAssertThrowsError(try ChatterboxMacRenderPlan.decode(Data(repeating: 0, count: ChatterboxMacRenderPlan.maximumEncodedBytes + 1), source: source)) {
            XCTAssertEqual($0 as? ChatterboxMacRenderPlanError, .budget)
        }
    }
    func testBadControlsRangesAndUnknownDeliveryNeverDefaultSilently() throws {
        let bytes = try ChatterboxMacRenderPlan(request: request()).encoded()
        for mode in 0..<5 {
            let mutated = try json(bytes) { payload in
                var annotations = try XCTUnwrap(payload["annotations"] as? [[String: Any]])
                switch mode {
                case 0:
                    var controls = try XCTUnwrap(annotations[0]["controls"] as? [String: Any])
                    controls["exaggerationBits"] = UInt32(0x7fc00000) // NaN is not a legal model option.
                    annotations[0]["controls"] = controls
                case 1: annotations[0]["length"] = 4 // Splits the NFD grapheme.
                case 2: annotations[1]["offset"] = 0
                case 3: annotations[0]["delivery"] = "unrecognized-style"
                default: payload["hasDirections"] = false
                }
                payload["annotations"] = annotations
            }
            XCTAssertThrowsError(try ChatterboxMacRenderPlan.decode(mutated, source: source))
        }
    }
    func testFreshWorkerRebindsSamePlanAndRejectsDifferentBackendOrSeed() async throws {
        let request = try request(), plan = try ChatterboxMacRenderPlan(request: request)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let sourceID = try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: "chapter:1",
            textSHA256: ChatterboxMacChapterRequest.hash(Data(source.utf8)), extractionRevision: "synthetic-1", utf16Length: source.utf16.count)
        let reader = ChatterboxMacResidentRenderer(testFactory: { PlanTestBackend(profile: "synthetic-plan") })
        let worker = ChatterboxMacResidentRenderer(testFactory: { PlanTestBackend(profile: "synthetic-plan") })
        let wrong = ChatterboxMacResidentRenderer(testFactory: { PlanTestBackend(profile: "another-profile") })
        _ = try await reader.prepare(); _ = try await worker.prepare(); _ = try await wrong.prepare()
        let original = try await reader.bindChapter(source: sourceID, request: request, session: session, gate: gate)
        let freshSession = try await gate.open(accountPartition: session.accountPartition)
        let submission = try ChapterSubmission(request: original.submission.request, originalText: source, session: freshSession)
        let replay = try ChatterboxMacRenderPlan.decode(plan.encoded(), source: source)
        let binding = try await worker.bindChapter(plan: replay, submission: submission, gate: gate)
        XCTAssertEqual(try binding.submission.request.renderKey(), try original.submission.request.renderKey())
        XCTAssertEqual(binding.submission.session, freshSession)
        do { _ = try await worker.bindChapter(plan: replay, submission: original.submission, gate: gate); XCTFail("producer epoch is not the current Worker epoch") }
        catch { XCTAssertEqual(error as? ChapterWorkerError, .accountMismatch) }
        do { _ = try await wrong.bindChapter(plan: replay, submission: submission, gate: gate); XCTFail("different actual backend must reject") }
        catch { XCTAssertEqual(error as? ChatterboxMacRenderPlanError, .recipeMismatch) }
        let other = try ChatterboxMacChapterRequest(text: source, language: request.language, delivery: request.delivery,
            direction: request.direction, grouping: request.grouping, performanceDirections: request.performanceDirections, seed: 10)
        do { _ = try await worker.bindChapter(plan: .init(request: other), submission: submission, gate: gate); XCTFail("different seed must reject") }
        catch { XCTAssertEqual(error as? ChatterboxMacRenderPlanError, .recipeMismatch) }
        await reader.shutdown(); await worker.shutdown(); await wrong.shutdown()
    }
}
#endif
