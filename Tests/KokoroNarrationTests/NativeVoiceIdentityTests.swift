import Testing
@testable import KokoroNarration

@Test func plusRetainsSelectedStyleAcrossAutomaticLanguageResolution() async throws {
    let model = NarrationModel.plus
    #expect(model.resolvedVoiceID("plus-m1-en-v1", language: "es") == "plus-m1-es-v1")
    #expect(model.resolvedVoiceID("plus-f1-es-v1", language: "en") == "plus-f1-en-v1")
    #expect(model.resolvedVoiceID(nil, language: "es") == "plus-f1-es-v1")
    let plan = try await NarrationPipeline().plan("La puerta estaba abierta.", model: model,
        bookID: "voice", chapterID: "1", narratorVoiceID: "plus-m1-en-v1", metadataLanguage: "es")
    #expect(plan.narratorVoiceID == "plus-m1-es-v1")
    #expect(plan.units.allSatisfy { $0.voiceID == "plus-m1-es-v1" })
    let female = try #require(model.nativeVoices.first { $0.id == "plus-f1-es-v1" })
    let male = try #require(model.nativeVoices.first { $0.id == "plus-m1-es-v1" })
    #expect(female.engineVoiceID == "dk-f1-v1")
    #expect(male.engineVoiceID == "dk-m1-v1")
    #expect(female.engineVoiceID != male.engineVoiceID)
}
