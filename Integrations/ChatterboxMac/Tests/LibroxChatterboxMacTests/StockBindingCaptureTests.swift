#if os(macOS)
import XCTest
import Testing
import Foundation
import CryptoKit
@testable import LibroxChapterWorker
import LibroxChatterbox
@testable import LibroxChatterboxPlanning
@testable import LibroxChatterboxMac
private struct CaptureStockBackend: ResidentChapterBackend {
    let profile = "synthetic-stock-descriptor-1", modelSHA256 = String(repeating: "b", count: 64), conditioningSHA256 = String(repeating: "c", count: 64)
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL, receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws { throw ChatterboxMacRendererError.unavailable }
}
final class StockBindingCaptureTests: XCTestCase {
    func testCaptureOriginalSourceBoundRenderKeys() throws {
        var keys: [String: String] = [:]
        for i in 0..<3 {
            let text = i == 1 ? "¡Sigue adelante!" : "Keep going."
            let directions = i == 2 ? try ChatterboxPerformanceDirections(source: text, annotations: [
                .init(range: NSRange(location: 0, length: text.utf16.count), originalText: text,
                    performance: .init(delivery: .urgent, strength: .strong), controls: .init(exaggeration: 0.9, guidance: 0.3, temperature: 0.8))
            ], scope: .chapterV1) : nil
            let options = try ChatterboxMacChapterRequest(text: text, language: i == 1 ? "es" : "en", delivery: i == 1 ? .lossless : .smaller,
                grouping: i == 1 ? .compatibleNarration(maxCharacters: 160) : .sentences, performanceDirections: directions, seed: i == 2 ? .max : 42)
            let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: "Cafe\u{301}:\(i)",
                textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), extractionRevision: "synthetic-source-1", utf16Length: text.utf16.count)
            let session = ChapterAccountSession(accountPartition: String(repeating: "a", count: 64), epoch: UUID())
            let binding = try ChatterboxMacChapterBinding(source: source, localRequest: options, rendererID: UUID(), backend: CaptureStockBackend(), session: session)
            let descriptor = try ChatterboxStockVoiceDescriptor(modelSHA256: CaptureStockBackend().modelSHA256,
                conditioningSHA256: CaptureStockBackend().conditioningSHA256, rendererProfile: CaptureStockBackend().profile)
            let prepared = try descriptor.prepareChapter(source: source, options: options, session: session)
            XCTAssertEqual(try prepared.submission.request.renderKey(), try binding.submission.request.renderKey())
            XCTAssertEqual(Data(prepared.submission.originalText.utf8), Data(text.utf8))
            XCTAssertEqual(prepared.plan.encoded(), try ChatterboxChapterRenderPlan(request: options).encoded())
            keys[String(i)] = try binding.submission.request.renderKey()
        }
        XCTAssertEqual(keys, ["0": "e7b22a3bdad4f9eeb039db8becf29b9a03f2d514545d1085d015a9486b7cf51d",
            "1": "19fb0873e669b8f5716c2e3113d85f6ec9aa54c09d227eb4dc682568133c5e45",
            "2": "882e285ae01c745eea6ccfa333aa827dcf174f76b6886a38a37592421cf90f98"])
    }
}
@Suite struct StockSourceBoundBindingTests {
    @Test func descriptorRequiresPreparedBackendAndCannotOutliveShutdown() async throws {
        let renderer = ChatterboxMacResidentRenderer(testFactory: { CaptureStockBackend() })
        await #expect(throws: ChatterboxMacRendererError.busy) { try await renderer.stockVoiceDescriptor() }
        _ = try await renderer.prepare()
        let descriptor = try await renderer.stockVoiceDescriptor()
        #expect(descriptor.modelSHA256 == CaptureStockBackend().modelSHA256)
        #expect(descriptor.conditioningSHA256 == CaptureStockBackend().conditioningSHA256)
        #expect(descriptor.rendererProfile == CaptureStockBackend().profile)
        await renderer.shutdown()
        await #expect(throws: ChatterboxMacRendererError.closed) { try await renderer.stockVoiceDescriptor() }
    }
    @Test func recipesAreBoundToActualChapterTextRatherThanCopiedFromCatalog() async throws {
        let descriptor = try ChatterboxStockVoiceDescriptor(modelSHA256: CaptureStockBackend().modelSHA256,
            conditioningSHA256: CaptureStockBackend().conditioningSHA256, rendererProfile: CaptureStockBackend().profile)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        var outputs: [ChatterboxPreparedChapterSubmission] = []
        for text in ["Keep going.", "Go beyond the horizon."] {
            let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: "chapter:1",
                textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), extractionRevision: "synthetic-1", utf16Length: text.utf16.count)
            outputs.append(try descriptor.prepareChapter(source: source, options: .init(text: text, language: "en"), session: session))
        }
        #expect(outputs[0].submission.request.recipe.expressionSHA256 != outputs[1].submission.request.recipe.expressionSHA256)
        #expect(outputs[0].submission.request.recipe.synthesisOptionsSHA256 != outputs[1].submission.request.recipe.synthesisOptionsSHA256)
        #expect(try outputs[0].submission.request.renderKey() != outputs[1].submission.request.renderKey())
    }
    @Test func normalizationMismatchIsRejectedWithoutSourceRewrite() async throws {
        let descriptor = try ChatterboxStockVoiceDescriptor(modelSHA256: CaptureStockBackend().modelSHA256,
            conditioningSHA256: CaptureStockBackend().conditioningSHA256, rendererProfile: CaptureStockBackend().profile)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let text = "Cafe\u{301}"
        let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: "chapter:1",
            textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), extractionRevision: "synthetic-1", utf16Length: text.utf16.count)
        #expect(throws: ChapterWorkerError.invalidIdentity) {
            try descriptor.prepareChapter(source: source, options: .init(text: "Café", language: "en"), session: session)
        }
    }
}
#endif
