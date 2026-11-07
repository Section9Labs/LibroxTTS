import Foundation
import Testing
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

private let characterScenes = [
    ("en", "Clara was her sister. James was her brother.\n“Open the door,” said Clara.\n“I have the key,” said James.\n“Then come inside,” said Clara."),
    ("es", "Clara era su hermana. Diego era su hermano.\n«Abre la puerta», dijo Clara.\n«Tengo la llave», dijo Diego.\n«Entonces entra», dijo Clara.")
]

@Test(arguments: ["en", "es"])
func nativeCharacterCatalogAndCastUseOnlyTheirOwnVoices(_ language: String) throws {
    let model = NarrationModel.plus
    let voices = model.characterVoiceCatalog(language: language)
    #expect(voices.map(\.id) == ["plus-f1-\(language)-v1", "plus-m1-\(language)-v1"])
    #expect(voices.map(\.gender) == [.female, .male])
    let cast = try model.makeVoiceCast(bookID: "book", language: language, narratorVoiceID: voices[0].id)
    #expect(cast.voicePool == [voices[1].id] && cast.voiceSharing == .reuseCompatible)
    #expect(throws: NarrationPipeline.PlanningError.self) {
        try model.makeVoiceCast(bookID: "book", language: language, narratorVoiceID: "af_heart")
    }
    #expect(NarrationModel.kokoroDesktop.characterVoiceCatalog(language: language).allSatisfy { !$0.id.hasPrefix("plus-") })
}

@Test func nativeCharactersSwitchVoicesAndRetainSourceRanges() async throws {
    for (language, text) in characterScenes {
        let plan = try await NarrationPipeline().plan(text, model: .plus, bookID: "book", chapterID: "one",
            narratorVoiceID: "plus-f1-\(language)-v1", language: language, characterVoices: true)
        let cast = try #require(plan.cast)
        #expect(cast.characters.count == 2)
        #expect(cast.characters[0].voiceID == "plus-f1-\(language)-v1")
        #expect(cast.characters[1].voiceID == "plus-m1-\(language)-v1")
        let dialogue = plan.units.filter { $0.role == .dialogue }
        #expect(dialogue.map(\.voiceID) == ["plus-f1-\(language)-v1", "plus-m1-\(language)-v1", "plus-f1-\(language)-v1"])
        #expect(dialogue.map(\.speakerID) == ["c1", "c2", "c1"])
        #expect(plan.units.filter { $0.role == .narration }.allSatisfy { $0.voiceID == plan.narratorVoiceID && $0.speakerID == nil })
        #expect(plan.bookPlan?.characterAttributionSupported == true)
        for unit in plan.units {
            #expect(unit.text == (text as NSString).substring(with: unit.range))
            #expect(unit.phonemes.isEmpty)
            #expect(try CTTokenizer.normalize(unit.synthesisText, language: language, completeSentence: false).unicodeScalars.count <= 500)
        }
    }
}

@Test func nativeCharactersPersistCorrectionsAliasesAndManualNarratorFallback() async throws {
    let pipeline = NarrationPipeline()
    let first = try await pipeline.plan(characterScenes[0].1, model: .plus, bookID: "book", chapterID: "one",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true)
    var cast = try #require(first.cast)
    try cast.setVoice("plus-m1-en-v1", for: "c1")
    try cast.setVoice(nil, for: "c2")
    try cast.addAlias("Claire", to: "c1")
    cast = try BookVoiceCast.restore(cast.encoded(), bookID: "book")
    let second = try await pipeline.plan("“Wait here,” said James. “I will return,” said Claire.", model: .plus,
        bookID: "book", chapterID: "two", narratorVoiceID: "plus-f1-en-v1", language: "en",
        cast: cast, characterVoices: true)
    #expect(second.cast == cast)
    #expect(second.units.first?.voiceID == "plus-f1-en-v1")
    #expect(second.units.contains { $0.speakerID == "c1" && $0.voiceID == "plus-m1-en-v1" })
    #expect(second.cast?.characters[1].voiceAssignment == .manual)
    #expect(second.cast?.characters[1].voiceID == nil)
}

@Test func nativeCharacterToggleOffPreservesAcceptedSingleNarratorGrouping() async throws {
    let pipeline = NarrationPipeline(), text = characterScenes[0].1
    let discovered = try await pipeline.plan(text, model: .plus, bookID: "book", chapterID: "one",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true)
    let original = try TextNativeNarrationPlanner.plan(text, voiceID: "plus-f1-en-v1")
    let off = try await pipeline.plan(text, model: .plus, bookID: "book", chapterID: "one",
        narratorVoiceID: "plus-f1-en-v1", language: "en", cast: discovered.cast, characterVoices: false)
    #expect(off.cast == discovered.cast)
    #expect(off.units.map(\.text) == original.map(\.text))
    #expect(off.units.map(\.synthesisText) == original.map(\.synthesisText))
    #expect(off.units.map(\.range) == original.map(\.range))
    #expect(off.units.map(\.boundaryAfter) == original.map(\.boundaryAfter))
    #expect(off.units.allSatisfy { $0.voiceID == "plus-f1-en-v1" })
}

@Test func nativeCharacterPlannerRejectsForeignCastsEvenWithToggleOff() async throws {
    let wrongVoice = try BookVoiceCast(bookID: "book", language: .english, narratorVoiceID: "af_heart", voicePool: [])
    let wrongBook = try NarrationModel.plus.makeVoiceCast(bookID: "other", language: "en", narratorVoiceID: "plus-f1-en-v1")
    let wrongLanguage = try NarrationModel.plus.makeVoiceCast(bookID: "book", language: "es", narratorVoiceID: "plus-f1-es-v1")
    for cast in [wrongVoice, wrongBook, wrongLanguage] {
        await #expect(throws: (any Error).self) {
            try await NarrationPipeline().plan("Hello there.", model: .plus, bookID: "book", chapterID: "one",
                narratorVoiceID: "plus-f1-en-v1", language: "en", cast: cast)
        }
    }
}

@Test func nativeUncertainDialogueDoesNotGuessAlternatingSpeakers() async throws {
    let text = "“Is anyone there?”\n“Yes, I am here.”"
    let plan = try await NarrationPipeline().plan(text, model: .plus, bookID: "unknown", chapterID: "one",
        narratorVoiceID: "plus-m1-en-v1", language: "en", characterVoices: true)
    #expect(plan.cast?.characters.isEmpty == true)
    #expect(plan.units.allSatisfy { $0.voiceID == "plus-m1-en-v1" && $0.speakerID == nil })
}

@Test func nativeCharacterLexiconAndUnicodeKeepBookOffsetsAndBoundedSpeech() async throws {
    let text = "Clara was her sister. James was her brother.\n“Dr. Vale has 42 lanterns 🪔,” said James.\n“" + String(repeating: "We shall wait by the café, ", count: 35) + "” said Clara."
    let plan = try await NarrationPipeline().plan(text, model: .plus, bookID: "unicode", chapterID: "one",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true,
        lexicon: SpokenTextLexicon(entries: [.init(written: "Dr.", spoken: "Doctor", language: "en")]))
    #expect(plan.units.contains { $0.synthesisText.contains("Doctor") && $0.voiceID == "plus-m1-en-v1" })
    #expect(plan.units.contains { $0.synthesisText.contains("forty-two") })
    #expect(plan.units.filter { $0.speakerID == "c2" }.count > 1)
    for unit in plan.units {
        #expect(unit.text == (text as NSString).substring(with: unit.range))
        #expect(Range(unit.range, in: text) != nil)
        #expect(try CTTokenizer.normalize(unit.synthesisText, language: "en", completeSentence: false).unicodeScalars.count <= 500)
    }
}

@Test func nativeLanguageSupportDoesNotPretendAttributionExistsEverywhere() async throws {
    #expect(NarrationModel.plus.characterVoiceCatalog(language: "de-DE").count == 2)
    #expect(!NarrationModel.plus.supportsAutomaticCharacterAttribution(language: "de"))
    let plan = try await NarrationPipeline().plan("Die Tür war offen.", model: .plus, bookID: "german", chapterID: "one",
        narratorVoiceID: "plus-m1-de-v1", language: "de", characterVoices: true)
    #expect(plan.cast == nil && plan.units.allSatisfy { $0.voiceID == "plus-m1-de-v1" })
}

@Test func nativeSpanishDashDialogueKeepsReportingClausesWithNarrator() async throws {
    let text = "Clara era su hermana. Diego era su hermano.\n—Trae la carta —dijo Diego—. La leeremos mañana.\n—De acuerdo —respondió Clara."
    let plan = try await NarrationPipeline().plan(text, model: .plus, bookID: "dash", chapterID: "one",
        narratorVoiceID: "plus-f1-es-v1", language: "es", characterVoices: true)
    #expect(plan.units.contains { $0.text.contains("Trae la carta") && $0.voiceID == "plus-m1-es-v1" && $0.role == .dialogue })
    #expect(plan.units.contains { $0.text.contains("dijo Diego") && $0.voiceID == "plus-f1-es-v1" && $0.role == .narration })
    #expect(plan.units.contains { $0.text.contains("La leeremos mañana") && $0.voiceID == "plus-m1-es-v1" })
    for unit in plan.units { #expect(unit.text == (text as NSString).substring(with: unit.range)) }
}

@Test func nativeExplicitNarratorChangePreservesExistingCharacterAssignments() async throws {
    let pipeline = NarrationPipeline()
    let first = try await pipeline.plan(characterScenes[0].1, model: .plus, bookID: "book", chapterID: "one",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true)
    let original = try #require(first.cast)
    let changed = try original.replacingNarrator(with: "plus-m1-en-v1")
    let plan = try await pipeline.plan(characterScenes[0].1, model: .plus, bookID: "book", chapterID: "two",
        narratorVoiceID: "plus-f1-en-v1", language: "en", cast: changed, characterVoices: true)
    #expect(plan.narratorVoiceID == "plus-m1-en-v1")
    #expect(plan.cast?.characterVoices == original.characterVoices)
    #expect(plan.units.filter { $0.role == .narration }.allSatisfy { $0.voiceID == "plus-m1-en-v1" })
}
