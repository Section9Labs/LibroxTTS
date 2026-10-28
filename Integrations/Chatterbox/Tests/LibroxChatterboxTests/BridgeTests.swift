import Foundation
import Testing
import KokoroNarration
import KokoroPronunciation
@testable import LibroxChatterbox

@Test func realPlannerBridgePreservesSourceAndCast() async throws {
    let text = "—Ven aquí —susurró Clara. La lluvia había cesado."
    let cast = try BookVoiceCast(bookID: "bridge", language: .spanish,
                                 narratorVoiceID: "ef_dora", voicePool: [])
    let plan = try await BookNarrationPlanner().plan(text, chapterID: "1", cast: cast)
    #expect(!plan.units.isEmpty)
    let file = URL(fileURLWithPath: "/not-loaded/test-voice.safetensors")
    for unit in plan.units {
        let request = try ChatterboxNarrationBridge.prepare(unit, source: text,
            followingAttribution: "susurró Clara", languageCode: "es",
            conditioningFiles: ["ef_dora": file])
        #expect(request.text == unit.text)
        #expect(request.sourceContext?.range == unit.range)
        #expect(request.sourceContext?.voiceID == unit.voiceID)
        #expect(request.sourceContext?.speakerID == unit.speakerID)
        #expect(request.sourceContext?.originalText == (text as NSString).substring(with: unit.range))
        #expect(request.conditioningFile == file)
        #expect(request.options.language == "es")
        #expect(request.options.sentencePause == 0)
    }
}

@Test func bridgeRequiresExplicitVoiceAndUsesPerformanceControls() async throws {
    let text = "Come here."
    let cast = try BookVoiceCast(bookID: "bridge", language: .english,
                                 narratorVoiceID: "af_heart", voicePool: [])
    let plan = try await BookNarrationPlanner().plan(text, chapterID: "1", cast: cast)
    let unit = try #require(plan.units.first)
    #expect(throws: ChatterboxNarrationError.sourceTextMismatch) {
        try ChatterboxNarrationBridge.prepare(unit, source: "Wrong text", languageCode: "en",
            conditioningFiles: ["af_heart": URL(fileURLWithPath: "/test.safetensors")])
    }
    #expect(throws: ChatterboxNarrationError.missingVoiceConditioning("af_heart")) {
        try ChatterboxNarrationBridge.prepare(unit, source: text, languageCode: "en", conditioningFiles: [:])
    }
    let request = try ChatterboxNarrationBridge.prepare(unit, source: text, languageCode: "en",
        conditioningFiles: ["af_heart": URL(fileURLWithPath: "/test.safetensors")],
        override: .init(delivery: .whisper, strength: .moderate))
    let performance = try #require(request.sourceContext?.performance)
    #expect(request.exaggeration == performance.chatterboxSuggestion.exaggeration)
    #expect(request.guidance == performance.chatterboxSuggestion.cfgWeight)
    #expect(performance.chatterboxSuggestion.unmappedDelivery == .whisper)
    #expect(request.text == text) // no invented [whisper] tags or prompt words
}

@Test func emptyUpstreamIsFailure() async throws {
    let narrator = ChatterboxNarrator { _ in AsyncThrowingStream { $0.finish() } }
    await #expect(throws: ChatterboxNarrationError.invalidAudio) {
        try await narrator.stream(ChatterboxRequest(text: "Hello", language: "en")) { _ in }
    }
    try await narrator.unload()
}
