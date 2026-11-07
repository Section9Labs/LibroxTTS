import Foundation
import Testing
import KokoroNarration
import LibroxTTS
import LibroxCTNative

@Test func previousSelectionsKeepTheirModelAndDelivery() throws {
    let basic = try JSONDecoder().decode(NarrationModel.self, from: Data("\"kokoroDesktop\"".utf8))
    #expect(basic.name == "Basic")
    #expect(basic.deliveryProfile == .enhanced)
    #expect(basic.deliveryIdentity == "profiled-narration-runtime-1")
    #expect(NarrationModel.compact.name == "Previous Basic")
    #expect(NarrationModel.plus.rawValue != NarrationModel.enhanced.rawValue)
    #expect(NarrationModel.plus.rawValue != basic.rawValue)
    #expect(NarrationModel.plus.dependencies.isEmpty)
    #expect(basic.dependencies == [.compact])
    #expect(NarrationModel.plus.requiresPlusAccess)
    #expect(!basic.requiresPlusAccess)
    #expect(NarrationAssets.repositoryID(.compact) == "mrbrutti/librox@kokoro-coreml-2026-10-15")
    #expect(NarrationAssets.repositoryID(.kokoroDesktop) == "narration-kokoroDesktop")
    #expect(try NarrationAssets.manifest(.plus).revision != NarrationAssets.manifest(.kokoroDesktop).revision)
}
@Test func nativePlanningPreservesReviewedContextAndOffsets() throws {
    let text = "For months, she had kept his chair beside the fire. Now he stood in the doorway, smiling through his tears. You came back. She took his cold hands in hers and led him into the warmth."
    let units = try TextNativeNarrationPlanner.plan(text, voiceID: "plus-f1-en-v1")
    #expect(units.count == 1)
    #expect(units.first?.text == text)
    #expect(units.first?.phonemes == "")
    #expect(units.first?.range == NSRange(location: 0, length: (text as NSString).length))
    #expect(throws: TextNativeNarrationPlanner.PlanningError.self) {
        try TextNativeNarrationPlanner.plan(text, voiceID: "af_heart")
    }
    let long = String(repeating: "She remembered the journey. ", count: 100)
    let plan = try TextNativeNarrationPlanner.plan(long, voiceID: "plus-f1-en-v1")
    #expect(plan.count > 1)
    for unit in plan {
        #expect(try CTTokenizer.normalize(unit.synthesisText, language: "en", completeSentence: false).unicodeScalars.count <= 500)
        #expect(unit.text == (long as NSString).substring(with: unit.range))
    }
    let symbols = String(repeating: "𝄞", count: 200)
    // Ornamental paragraphs contain no narration, just like blank EPUB lines.
    #expect(try TextNativeNarrationPlanner.plan(symbols, voiceID: "plus-f1-en-v1").isEmpty)
}
@Test func failedLoadAndUnloadDoNotLeaveUsableRenderer() async throws {
    let missing = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let renderer = NarrationRenderer(compactDirectory: missing, harmonicSource: nil)
    await #expect(throws: (any Error).self) { try await renderer.load(.plus, directory: missing) }
    await renderer.unload()
    let unit = try #require(TextNativeNarrationPlanner.plan("Come back.", voiceID: "plus-f1-en-v1").first)
    await #expect(throws: (any Error).self) { try await renderer.render(unit) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_TEST_ASSETS"] != nil))
func modelReplacementRetiresPlusAndRecoversAfterMissingBasicAssets() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["CT_TEST_ASSETS"])
    let assets = URL(fileURLWithPath: path)
    let missing = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let renderer = NarrationRenderer(compactDirectory: missing, harmonicSource: nil)
    let unit = try #require(TextNativeNarrationPlanner.plan("She came home.", voiceID: "plus-f1-en-v1").first)
    try await renderer.load(.plus, directory: assets)
    let audio = try await renderer.render(unit)
    #expect(audio.count > 24_000)
    #expect(audio.allSatisfy { $0.isFinite && abs($0) <= 1 })
    await #expect(throws: (any Error).self) { try await renderer.load(.kokoroDesktop, directory: missing) }
    await #expect(throws: (any Error).self) { try await renderer.render(unit) }
    try await renderer.load(.plus, directory: assets)
    await renderer.unload()
    await #expect(throws: (any Error).self) { try await renderer.render(unit) }
}
