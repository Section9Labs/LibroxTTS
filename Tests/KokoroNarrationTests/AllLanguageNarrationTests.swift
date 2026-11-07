import Foundation
import Testing
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

struct AllLanguageNarrationTests {
    // Literal reporting fixtures independent of the implementation's rule tables.
    static let cases: [(String, String, String, String, String)] = [
        ("en", "Anna", "Anna said: ", "“", "”"),
        ("es", "Ana", "Ana dijo: ", "«", "»"),
        ("fr", "Anne", "Anne dit : ", "«", "»"),
        ("de", "Anna", "Anna sagte: ", "„", "“"),
        ("it", "Anna", "Anna disse: ", "«", "»"),
        ("pt", "Ana", "Ana disse: ", "“", "”"),
        ("nl", "Anna", "Anna zei: ", "“", "”"),
        ("da", "Anna", "Anna sagde: ", "“", "”"),
        ("sv", "Anna", "Anna sade: ", "“", "”"),
        ("fi", "Aino", "Aino sanoi: ", "“", "”"),
        ("et", "Mari", "Mari ütles: ", "“", "”"),
        ("lv", "Anna", "Anna teica: ", "“", "”"),
        ("lt", "Ona", "Ona pasakė: ", "“", "”"),
        ("pl", "Anna", "Anna powiedziała: ", "„", "“"),
        ("cs", "Anna", "Anna řekla: ", "„", "“"),
        ("sk", "Anna", "Anna povedala: ", "„", "“"),
        ("sl", "Ana", "Ana je rekla: ", "“", "”"),
        ("hr", "Ana", "Ana je rekla: ", "“", "”"),
        ("bg", "Анна", "Анна каза: ", "„", "“"),
        ("ru", "Анна", "Анна сказала: ", "«", "»"),
        ("uk", "Анна", "Анна сказала: ", "«", "»"),
        ("ro", "Ana", "Ana spuse: ", "„", "“"),
        ("hu", "Anna", "Anna mondta: ", "„", "“"),
        ("el", "Άννα", "Άννα είπε: ", "«", "»"),
        ("tr", "Ada", "Ada dedi: ", "“", "”"),
        ("id", "Ayu", "Ayu berkata: ", "“", "”"),
        ("vi", "Lan", "Lan nói: ", "“", "”"),
        ("ar", "ليلى", "قالت ليلى: ", "«", "»"),
        ("hi", "मीरा", "मीरा ने कहा: ", "“", "”"),
        ("ja", "太郎", "太郎は言った：", "「", "」"),
        ("ko", "민수", "민수는 말했다: ", "“", "”")
    ]

    @Test func allDeclaredLanguagesHaveFixturesRulesAndCasting() {
        #expect(Set(Self.cases.map { $0.0 }) == Set(NarrationModel.plus.supportedLanguageCodes))
        #expect(NarrationModel.plus.supportedLanguageCodes.allSatisfy {
            NarrationModel.plus.supportsAutomaticCharacterAttribution(language: $0)
                && NarrationLanguageRules.profiles[$0] != nil
        })
    }

    @Test(arguments: cases)
    func localizedReportingTagsPersistVoicesAndKeepOriginalText(_ fixture: (String, String, String, String, String)) async throws {
        let (language, name, prefix, open, close) = fixture
        let sample = try #require(NarrationLanguage.sampleText(language))
        let text = prefix + open + sample + close
        let voice = "plus-f1-\(language)-v1"
        let pipeline = NarrationPipeline()
        let plan = try await pipeline.plan(text, model: .plus, bookID: "languages", chapterID: "one",
            narratorVoiceID: voice, language: language, characterVoices: true)
        var cast = try #require(plan.cast)
        let character = try #require(cast.characters.first, "Missing speaker: \(language) \(text)")
        #expect(character.name == name)
        #expect(plan.units.contains { $0.role == .dialogue && $0.voiceID != voice && $0.speakerID == character.id })
        #expect(cast.language.rawValue == language)
        try cast.setVoice("plus-m5-\(language)-v1", for: character.id)
        cast = try BookVoiceCast.restore(cast.encoded(), bookID: "languages")
        let next = name + ": " + open + sample + close
        let repeated = try await pipeline.plan(next, model: .plus, bookID: "languages", chapterID: "two",
            narratorVoiceID: voice, language: language, cast: cast, characterVoices: true)
        #expect(repeated.cast?.characters.count == 1)
        #expect(repeated.units.contains { $0.role == .dialogue && $0.voiceID == "plus-m5-\(language)-v1" })
        for (source, units) in [(text, plan.units), (next, repeated.units)] {
            for unit in units {
                #expect(unit.text == (source as NSString).substring(with: unit.range))
                #expect(try CTTokenizer.normalize(unit.synthesisText, language: language, completeSentence: false).unicodeScalars.count <= 500)
            }
        }
        try cast.setVoice(nil, for: character.id)
        let disabled = try await pipeline.plan(next, model: .plus, bookID: "languages", chapterID: "three",
            narratorVoiceID: voice, language: language, cast: cast, characterVoices: true)
        #expect(disabled.units.allSatisfy { $0.voiceID == voice })
        #expect(disabled.cast?.characters.first?.voiceAssignment == .manual)
    }

    @Test(arguments: cases)
    func everyLanguageKeepsStageDirectionsWithNarrator(_ fixture: (String, String, String, String, String)) async throws {
        let (language, name, prefix, open, close) = fixture
        let sample = try #require(NarrationLanguage.sampleText(language))
        let cue = try #require(NarrationLanguageRules.profiles[language]?.directionCues.first)
        let capitalized = cue.prefix(1).uppercased() + cue.dropFirst()
        let source = prefix + open + sample + close + "\n\n" + name + ": (" + capitalized + ".) " + sample
        let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "stage", chapterID: "one",
            narratorVoiceID: "plus-f1-\(language)-v1", language: language, characterVoices: true)
        #expect(plan.units.contains { $0.text.contains(capitalized) && $0.role == .attribution && $0.voiceID == "plus-f1-\(language)-v1" })
        #expect(plan.units.last?.role == .dialogue && plan.units.last?.voiceID != "plus-f1-\(language)-v1")
    }

    @Test(arguments: cases)
    func untaggedSpeechNeverGuessesSpeakers(_ fixture: (String, String, String, String, String)) async throws {
        let (language, _, _, open, close) = fixture
        let sample = try #require(NarrationLanguage.sampleText(language))
        let source = open + sample + close + "\n" + open + sample + close
        let voice = "plus-f1-\(language)-v1"
        let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "unknown", chapterID: "one",
            narratorVoiceID: voice, language: language, characterVoices: true)
        #expect(plan.cast?.characters.isEmpty == true)
        #expect(plan.units.allSatisfy { $0.voiceID == voice })
    }

    @Test(arguments: cases)
    func pronounsAndConflictingNamedTagsNeverSelectAVoice(_ fixture: (String, String, String, String, String)) async throws {
        let (language, _, _, open, close) = fixture
        let sample = try #require(NarrationLanguage.sampleText(language))
        let excluded = try #require(NarrationLanguageRules.profiles[language]?.excludedNames.sorted().first)
        let capitalized = excluded.prefix(1).uppercased() + excluded.dropFirst()
        let voice = "plus-f1-\(language)-v1"
        let plan = try await NarrationPipeline().plan(capitalized + ": " + open + sample + close,
            model: .plus, bookID: "pronouns", chapterID: "one", narratorVoiceID: voice,
            language: language, characterVoices: true)
        #expect(plan.cast?.characters.isEmpty == true)
        #expect(plan.units.allSatisfy { $0.voiceID == voice })
    }

    @Test(arguments: [
        ("de", "Anna", "„Die Tür ist offen“, sagte Anna."),
        ("fr", "Anne", "«La porte est ouverte», dit Anne."),
        ("ru", "Анна", "«Дверь открыта», сказала Анна."),
        ("ar", "ليلى", "«الباب مفتوح»، قالت ليلى."),
        ("hi", "मीरा", "“दरवाज़ा खुला है”, मीरा ने कहा।"),
        ("ja", "太郎", "「扉が開いている」と太郎は言った。"),
        ("ko", "민수", "“문이 열려 있어요”라고 민수는 말했다.")
    ])
    func trailingTagsWorkAcrossScripts(_ fixture: (String, String, String)) async throws {
        let (language, name, source) = fixture
        let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "suffix", chapterID: "one",
            narratorVoiceID: "plus-f1-\(language)-v1", language: language, characterVoices: true)
        #expect(plan.cast?.characters.first?.name == name)
    }

    @Test(arguments: NarrationModel.plus.supportedLanguageCodes)
    func allLanguagesShareSpokenOverridesAndNumericPreparation(_ language: String) throws {
        let lexicon = SpokenTextLexicon(entries: [.init(written: "XYZ", spoken: "Ada", language: language)])
        let source = "XYZ 42"
        let spoken = lexicon.text(source, language: language)
        #expect(spoken.hasPrefix("Ada "))
        #expect(!spoken.contains("42"), "No localized numeric reading for \(language): \(spoken)")
        let plan = try TextNativeNarrationPlanner.plan(source, voiceID: "plus-f1-\(language)-v1", lexicon: lexicon)
        #expect(plan.first?.text == source && plan.first?.synthesisText == spoken)
        for invalid in ["version 1.2.3", "id_123", "2026-02-30", "25:61"] where !["en", "es", "fr", "it", "pt", "hi", "ja"].contains(language) {
            #expect(lexicon.text(invalid, language: language) == invalid)
        }
    }

    @Test func oldCastLanguageEncodingRemainsAString() throws {
        let cast = try BookVoiceCast(bookID: "old", language: .english, narratorVoiceID: "af_heart", voicePool: [])
        let json = try #require(JSONSerialization.jsonObject(with: cast.encoded()) as? [String: Any])
        #expect(json["language"] as? String == "en")
        #expect(try BookVoiceCast.restore(cast.encoded(), bookID: "old") == cast)
    }
}
