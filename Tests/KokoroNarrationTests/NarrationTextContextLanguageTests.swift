import CryptoKit
import Foundation
import Testing
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

struct NarrationTextContextLanguageTests {
    typealias Fixture = (String, String, String, String, String)

    private func prepared(_ fixture: Fixture, stressPrefix: Bool) async throws -> (String, NarrationPipeline.Plan) {
        let (language, name, prefix, open, close) = fixture
        let sample = try #require(NarrationLanguage.sampleText(language))
        // Keep the literal supported reporting tag while exercising decomposed
        // speech, filtered emoji, numbers and a spoken override inside the unit.
        let speech = ("🌙 XYZ 42. " + sample).decomposedStringWithCanonicalMapping
        // The second variant is the exact reporting-prefix reproduction that
        // previously prevented dialogue discovery in 29 languages.
        let source = stressPrefix
            ? ("🌙 " + prefix + open + "XYZ 42. " + sample + close + " " + sample).decomposedStringWithCanonicalMapping
            : prefix + open + speech + close + " " + sample.decomposedStringWithCanonicalMapping
        let lexicon = SpokenTextLexicon(entries: [.init(written: "XYZ", spoken: name, language: language)])
        let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "context-languages",
            chapterID: language, narratorVoiceID: "plus-f1-\(language)-v1", language: language,
            characterVoices: true, lexicon: lexicon)
        return (source, plan)
    }

    private func binding(_ plan: NarrationPipeline.Plan, index: Int, source: String,
                         language: String) throws -> CTTextContext.Binding {
        let voice = try #require(NarrationModel.plus.nativeVoices.first { $0.id == plan.units[index].voiceID })
        return try NarrationTextContext.surrounding(plan.units, index: index, source: source,
            language: language, modelFingerprint: CTTextContext.modelFingerprint(), styleID: voice.styleID)
    }

    @Test(arguments: AllLanguageNarrationTests.cases, [false, true])
    func preparedDialogueKeepsExactNormalizedTokens(_ fixture: Fixture, _ stressPrefix: Bool) async throws {
        let language = fixture.0
        let (source, plan) = try await prepared(fixture, stressPrefix: stressPrefix)
        let index = try #require(plan.units.firstIndex { $0.role == .dialogue && $0.text.contains("XYZ") })
        let unit = plan.units[index]
        #expect((source as NSString).substring(with: unit.range) == unit.text)
        #expect(!unit.synthesisText.contains("XYZ") && !unit.synthesisText.contains("42"))
        let bound = try binding(plan, index: index, source: source, language: language)
        #expect(!bound.isIdentity)
        #expect(bound.normalizedContext.unicodeScalars.count <= 512)
        let scalars = Array(bound.normalizedContext.unicodeScalars)
        #expect(try String(String.UnicodeScalarView(bound.gatherIndices.map { scalars[$0] }))
            == CTTokenizer.normalize(unit.synthesisText, language: language, completeSentence: false))
        let restored = try JSONDecoder().decode(CTTextContext.Binding.self, from: JSONEncoder().encode(bound))
        #expect(CTTextContext.validates(restored, spokenText: unit.synthesisText, language: language,
            modelFingerprint: bound.modelFingerprint, styleID: bound.styleID))
        #expect(!CTTextContext.validates(restored, spokenText: unit.synthesisText, language: language,
            modelFingerprint: "previous-assets", styleID: bound.styleID))
        #expect(!CTTextContext.validates(restored, spokenText: unit.synthesisText, language: language,
            modelFingerprint: bound.modelFingerprint, styleID: "wrong-style"))
    }

    // Read only the pinned production tokenizer table. No model is loaded and
    // this does not imply native audio or pronunciation acceptance in a language.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CT_CONTEXT_TOKENIZER_ASSETS"] != nil),
          arguments: AllLanguageNarrationTests.cases, [false, true])
    func gatheredProductionTokenIDsMatchIsolatedSpeech(_ fixture: Fixture, _ stressPrefix: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CT_CONTEXT_TOKENIZER_ASSETS"])
        let directory = URL(fileURLWithPath: path)
        let pinned = try #require(CTAssets.manifest().files.first { $0.path == "config/unicode_indexer.json" })
        let data = try Data(contentsOf: directory.appendingPathComponent(pinned.path))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == pinned.sha256)
        let tokenizer = try CTTokenizer(directory: directory)
        let (source, plan) = try await prepared(fixture, stressPrefix: stressPrefix)
        let indices = plan.units.indices.filter { plan.units[$0].role == .dialogue }
        #expect(!indices.isEmpty)
        for index in indices {
            let bound = try binding(plan, index: index, source: source, language: fixture.0)
            let contextIDs = try tokenizer.encode(bound.contextText, language: fixture.0, completeSentence: false)
            let spokenIDs = try tokenizer.encode(plan.units[index].synthesisText, language: fixture.0, completeSentence: false)
            #expect(bound.gatherIndices.map { contextIDs[$0] } == spokenIDs)
        }
    }

    @Test(arguments: AllLanguageNarrationTests.cases)
    func stageContextRetainsPreparedReadingsWithinItsParagraph(_ fixture: Fixture) async throws {
        let (language, name, prefix, open, close) = fixture
        let sample = try #require(NarrationLanguage.sampleText(language))
        let cue = try #require(NarrationLanguageRules.profiles[language]?.directionCues.first)
        let direction = cue.prefix(1).uppercased() + cue.dropFirst()
        let source = prefix + open + sample + close + "\n\n" + name + ": (" + direction + ".) XYZ 42. " + sample
        let lexicon = SpokenTextLexicon(entries: [.init(written: "XYZ", spoken: name, language: language)])
        let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "context-stage",
            chapterID: language, narratorVoiceID: "plus-f1-\(language)-v1", language: language,
            characterVoices: true, lexicon: lexicon)
        let index = try #require(plan.units.lastIndex { $0.role == .dialogue && $0.text.contains("XYZ") })
        let bound = try binding(plan, index: index, source: source, language: language)
        #expect(!bound.isIdentity)
        #expect(bound.contextText.contains(direction))
        #expect(!bound.contextText.contains(prefix + open))
        #expect(!bound.contextText.contains("XYZ") && !bound.contextText.contains("42"))
        #expect(CTTextContext.validates(bound, spokenText: plan.units[index].synthesisText, language: language,
            modelFingerprint: bound.modelFingerprint, styleID: bound.styleID))
    }

    @Test(arguments: AllLanguageNarrationTests.cases)
    func repeatedQuotationsHaveDistinctGatherAndRenderIdentity(_ fixture: Fixture) throws {
        let (language, _, _, open, close) = fixture
        let sample = try #require(NarrationLanguage.sampleText(language))
        let spoken = open + sample + close
        let source = spoken + " " + spoken
        func bind(_ range: NSRange) throws -> CTTextContext.Binding {
            try CTTextContext.bind(contextText: source, spokenRange: range, spokenText: spoken,
                language: language, modelFingerprint: "repeated-source", styleID: "F1")
        }
        let first = try bind((source as NSString).range(of: spoken))
        let last = try bind((source as NSString).range(of: spoken, options: .backwards))
        #expect(first.normalizedSpoken == last.normalizedSpoken)
        #expect(first.gatherIndices != last.gatherIndices)
        #expect(first.featureCacheKey == last.featureCacheKey)
        #expect(first.renderCacheKey != last.renderCacheKey)
    }
}
