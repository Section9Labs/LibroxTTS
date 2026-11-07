import Testing
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

@Test(arguments: CTAssets.styles)
func everyNativeStyleSurvivesEverySupportedLanguage(_ style: String) {
    let model = NarrationModel.plus
    for language in model.supportedLanguageCodes {
        let id = "plus-\(style.lowercased())-\(language)-v1"
        #expect(model.resolvedVoiceID("plus-\(style.lowercased())-en-v1", language: language) == id)
        let voice = model.nativeVoices.first { $0.id == id }
        #expect(voice?.engineVoiceID == "dk-\(style.lowercased())-v1")
        #expect(CTAssets.voiceStyles[voice?.engineVoiceID ?? ""] == style)
    }
}

@Test func expandingNativeVoicePoolPreservesAssignmentsAliasesAndManualFallback() async throws {
    var original = try BookVoiceCast(bookID: "old", language: .english, narratorVoiceID: "plus-f1-en-v1",
        voicePool: ["plus-m1-en-v1"], voiceGenders: ["plus-f1-en-v1": .female, "plus-m1-en-v1": .male],
        voiceSharing: .reuseCompatible)
    let first = try await NarrationPipeline().plan("Clara was her sister. James was her brother. “Wait,” said Clara. “Here,” said James.",
        model: .plus, bookID: "old", chapterID: "one", narratorVoiceID: original.narratorVoiceID,
        language: "en", cast: original, characterVoices: true)
    original = try #require(first.cast)
    try original.setVoice(nil, for: "c2")
    try original.addAlias("Claire", to: "c1")
    var expanded = try NarrationModel.plus.expandingVoiceCatalog(in: original)
    #expect(expanded.characters == original.characters && expanded.aliases == original.aliases)
    #expect(expanded.voicePool.count == 9 && expanded.voicePool.first == "plus-m1-en-v1")
    #expect(expanded.narratorVoiceID == original.narratorVoiceID)
    try expanded.setVoice("plus-f5-en-v1", for: "c1")
    #expect(expanded.characterVoices["c1"] == "plus-f5-en-v1")
    #expect(expanded.characters[1].voiceAssignment == .manual && expanded.characters[1].voiceID == nil)
    #expect(throws: NarrationPipeline.PlanningError.self) { try NarrationModel.kokoroDesktop.expandingVoiceCatalog(in: original) }
}

@Test func kokoroAndNativeBothCreateUsefulCastsThroughTheSharedEntryPoint() async throws {
    for (model, voice) in [(NarrationModel.kokoroDesktop, "af_heart"), (.plus, "plus-f1-en-v1")] {
        let plan = try await NarrationPipeline().plan("James was her brother. “Open the door,” said James.",
            model: model, bookID: "shared", chapterID: "one", narratorVoiceID: voice, language: "en", characterVoices: true)
        #expect(plan.cast?.characters.count == 1)
        #expect(plan.units.contains { $0.speakerID != nil && $0.voiceID != voice })
    }
}

@Test func unsupportedDeliverySettingsDoNotCreateDifferentNativeRequests() {
    let selected = NarrationDeliveryOptions(expressive: true, blendedVoice: true)
    #expect(NarrationModel.plus.resolvedDeliveryOptions(selected) == .init(blendedVoice: true))
    #expect(NarrationModel.compact.resolvedDeliveryOptions(selected) == .init(expressive: true))
    #expect(NarrationModel.kokoroDesktop.resolvedDeliveryOptions(selected) == selected)
    #expect(!NarrationModel.plus.supportsPronunciationDialect)
}
