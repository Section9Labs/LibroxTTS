import Foundation
import Testing
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

struct BasicPlusParityTests {
    @Test(arguments: [NarrationModel.kokoroDesktop, .plus])
    func spanishStageDirectionsUseNarratorAndSavedCharacterVoice(_ model: NarrationModel) async throws {
        let narrator = try #require(model.resolvedVoiceID(nil, language: "es"))
        let pipeline = NarrationPipeline()
        let discovered = try await pipeline.plan("Clara era su hermana. «Ven aquí», dijo Clara.",
            model: model, bookID: "play", chapterID: "one", narratorVoiceID: narrator,
            language: "es", characterVoices: true)
        var cast = try #require(discovered.cast)
        let character = try #require(cast.characters.first)
        let characterVoice = try #require(model.characterVoiceCatalog(language: "es").first { $0.id != narrator }?.id)
        try cast.setVoice(characterVoice, for: character.id)
        let source = "CLARA.—(Con alegría.) Ya estás aquí.\n\nDESCONOCIDO.—(Con solemnidad.) Nadie me conoce."
        let plan = try await pipeline.plan(source, model: model, bookID: "play", chapterID: "two",
            narratorVoiceID: narrator, language: "es", cast: cast, characterVoices: true)
        #expect(plan.units.contains { $0.role == .attribution && $0.text.contains("Con alegría") && $0.voiceID == narrator })
        #expect(plan.units.contains { $0.role == .dialogue && $0.text.contains("Ya estás")
            && $0.speakerID == character.id && $0.voiceID == characterVoice })
        #expect(plan.units.contains { $0.role == .dialogue && $0.text.contains("Nadie me") && $0.voiceID == narrator })
        #expect(plan.cast?.characters.count == cast.characters.count)
        for unit in plan.units {
            #expect(unit.text == (source as NSString).substring(with: unit.range))
            if unit.role == .attribution { #expect(unit.voiceID == narrator && unit.speakerID == nil) }
        }
    }

    @Test func nativeStageParsingDoesNotChangeDisabledCharacterMode() async throws {
        let text = "CLARA.—(Con alegría.) Ya estás aquí."
        let reference = try TextNativeNarrationPlanner.plan(text, voiceID: "plus-f1-es-v1")
        let plan = try await NarrationPipeline().plan(text, model: .plus, bookID: "play", chapterID: "one",
            narratorVoiceID: "plus-f1-es-v1", language: "es", characterVoices: false)
        #expect(plan.units.map(\.synthesisText) == reference.map(\.synthesisText))
        #expect(plan.units.map(\.range) == reference.map(\.range))
    }

    @Test func expandedNativeNumbersKeepOffsetsAndFitActualTokenizer() async throws {
        let text = "“" + String(repeating: "The 101st reading was -1,234.05, ", count: 24) + "” she said."
        let plan = try await NarrationPipeline().plan(text, model: .plus, bookID: "numbers", chapterID: "one",
            narratorVoiceID: "plus-f1-en-v1", language: "en")
        #expect(plan.units.count > 1)
        #expect(plan.units.contains { $0.synthesisText.contains("one hundred first") })
        for unit in plan.units {
            #expect(unit.text == (text as NSString).substring(with: unit.range))
            #expect(try CTTokenizer.normalize(unit.synthesisText, language: "en", completeSentence: false).unicodeScalars.count <= 500)
        }
    }

    @Test func basicOnlyLanguagesRemainAnExplicitParityGap() {
        let missing = Set(NarrationModel.kokoroDesktop.supportedLanguageCodes)
            .subtracting(NarrationModel.plus.supportedLanguageCodes)
        // Do not silently claim Chinese support or reroute a Plus request to Basic.
        #expect(missing == ["zh"])
        #expect(NarrationModel.plus.resolvedVoiceID(nil, language: "zh") == nil)
    }
}
