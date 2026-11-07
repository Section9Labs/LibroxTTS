import Foundation
import Testing
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

@Test(arguments: NarrationLanguage.textNativeCodes)
func everyDeclaredLanguageHasARealPreviewAndTokenBudget(_ language: String) throws {
    let sample = try #require(NarrationLanguage.sampleText(language))
    let voice = try #require(NarrationModel.plus.resolvedVoiceID(nil, language: language))
    let units = try TextNativeNarrationPlanner.plan(sample, voiceID: voice)
    #expect(!units.isEmpty)
    for unit in units {
        let normalized = try CTTokenizer.normalize(unit.synthesisText, language: language, completeSentence: false)
        #expect(normalized.hasPrefix("<\(language)>"))
        #expect(normalized.unicodeScalars.count <= 500)
        #expect(unit.prosody != nil)
        #expect(unit.text == (sample as NSString).substring(with: unit.range))
    }
}

@Test func longSentenceKeepsContextAndForcedFragmentsNeverInventPeriods() throws {
    let sentence = "She remembered " + String(repeating: "the quiet room and the open window, ", count: 9) + "but she could not go back."
    #expect(sentence.count > 280 && sentence.count < 480)
    let intact = try TextNativeNarrationPlanner.plan(sentence, voiceID: "plus-f1-en-v1")
    #expect(intact.count == 1)
    #expect(intact[0].text == sentence)
    let long = String(repeating: "the quiet room and the open window ", count: 40) + "waited."
    let fragments = try TextNativeNarrationPlanner.plan(long, voiceID: "plus-f1-en-v1")
    #expect(fragments.count > 1)
    #expect(fragments.dropLast().allSatisfy { $0.boundaryAfter == .continuation })
    for fragment in fragments.dropLast() {
        let normalized = try CTTokenizer.normalize(fragment.synthesisText, language: "en", completeSentence: false)
        #expect(!normalized.hasSuffix(".</en>"))
    }
}

@Test func sharedReadingsPreserveSourceOffsetsAcrossBackends() async throws {
    let source = "Dr. Vale waited beside 42 lanterns."
    let lexicon = SpokenTextLexicon(entries: [.init(written: "Dr.", spoken: "Doctor", language: "en")])
    let pipeline = NarrationPipeline()
    for (model, voice) in [(NarrationModel.plus, "plus-f1-en-v1"), (.kokoroDesktop, "af_heart")] {
        let plan = try await pipeline.plan(source, model: model, bookID: "test", chapterID: "1",
            narratorVoiceID: voice, language: "en", lexicon: lexicon)
        #expect(plan.units.contains { $0.synthesisText.contains("Doctor") })
        for unit in plan.units {
            #expect(unit.text == (source as NSString).substring(with: unit.range))
            #expect(unit.prosody != nil)
        }
        if model == .plus { #expect(plan.units.contains { $0.synthesisText.contains("forty-two") }) }
        else { #expect(plan.units.contains { !$0.phonemes.isEmpty }) }
    }
}

@Test func automaticLanguageAndUnsupportedLanguagesDoNotChangeModelsSilently() async throws {
    #expect(NarrationModel.plus.supportedLanguageCodes.count == 31)
    #expect(NarrationLanguage.normalize("deu-DE") == "de")
    let pipeline = NarrationPipeline()
    let plan = try await pipeline.plan(try #require(NarrationLanguage.sampleText("de")), model: .plus,
        bookID: "german", chapterID: "1", narratorVoiceID: "plus-f1-en-v1", metadataLanguage: "de-DE")
    #expect(plan.language == "de" && plan.narratorVoiceID == "plus-f1-de-v1")
    await #expect(throws: NarrationPipeline.PlanningError.self) {
        try await pipeline.plan("中文", model: .plus, bookID: "unsupported", chapterID: "1",
                                narratorVoiceID: nil, language: "zh")
    }
}

@Test func nativeDeliveryPreservesBetweenPassageDynamics() throws {
    let loud = (0..<44_100).map { Float(0.4 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
    let quiet = loud.map { $0 * 0.25 }
    let a = try CTDelivery.prepare(loud, sampleRate: 44_100, level: .nativeDynamics)
    let b = try CTDelivery.prepare(quiet, sampleRate: 44_100, level: .nativeDynamics)
    let gain = Float(pow(10, CTDelivery.nativeGainDB / 20))
    #expect(a.samples == loud.map { $0 * gain } && b.samples == quiet.map { $0 * gain })
    #expect(abs(a.gainDB - CTDelivery.nativeGainDB) < 1e-10 && abs(a.gainDB - b.gainDB) < 1e-10)
    #expect(abs((try CTDelivery.integratedLoudness(a.samples) - CTDelivery.integratedLoudness(b.samples)) - 12.0412) < 0.001)
}

@Test(arguments: ["\n \n", "\r\n \r\n", "\u{2029}\u{2029}"])
func nativeDialogueParagraphsSkipBlankTokensAndKeepSourceRanges(_ separator: String) throws {
    let first = "  ‘Morning,’ she said, standing beside the gate.   "
    let second = "  ‘Morning,’ he replied.   ‘Have you brought the letter?’   "
    let text = first + separator + second
    let units = try TextNativeNarrationPlanner.plan(text, voiceID: "plus-f1-en-v1")
    #expect(units.count == 2)
    #expect(units.first?.boundaryAfter == .paragraph)
    for (unit, expected) in zip(units, [first, second]) {
        #expect(unit.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(unit.text == (text as NSString).substring(with: unit.range))
        #expect(!unit.text.contains { $0.isNewline })
        _ = try CTTokenizer.normalize(unit.synthesisText, language: "en", completeSentence: false)
    }
}

@Test func nativeLongQuotedSentenceCanGrowPastItsNonspeakingPrefix() throws {
    let text = "  ‘" + String(repeating: "The window was open and the room was quiet, ", count: 24) + "she remembered.’"
    let units = try TextNativeNarrationPlanner.plan(text, voiceID: "plus-f1-en-v1")
    #expect(units.count > 1)
    #expect(units.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            == text.trimmingCharacters(in: .whitespacesAndNewlines))
    for unit in units {
        #expect(unit.text == (text as NSString).substring(with: unit.range))
        #expect(try CTTokenizer.normalize(unit.synthesisText, language: "en", completeSentence: false).unicodeScalars.count <= 500)
    }
}

@Test func nativeEmptyAndOrnamentalParagraphsProduceNoAudioUnits() throws {
    for text in [" \n \n ", "⁂\n* * *\n—", "“”\n‘’"] {
        #expect(try TextNativeNarrationPlanner.plan(text, voiceID: "plus-f1-en-v1").isEmpty)
    }
}
