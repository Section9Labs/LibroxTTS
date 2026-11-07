import Foundation
import Testing
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

struct SharedDeliveryParityTests {
    @Test(arguments: AllLanguageNarrationTests.cases)
    func namedReportingSeamsUseSharedLanguageRules(_ fixture: (String, String, String, String, String)) {
        let (language, _, prefix, open, close) = fixture
        let decision = DialogueTiming.classify(.init(previousText: prefix, nextText: open + "XYZ" + close,
            languageCode: language))
        #expect(decision.kind == .attribution)
    }

    @Test(arguments: NarrationModel.plus.supportedLanguageCodes)
    func nativeCadenceIsOptInAndResetsAtResume(_ language: String) {
        let unit = BookNarrationUnit(sourceText: "XYZ", sourceRange: NSRange(location: 0, length: 3),
            narratorID: "plus-f1-\(language)-v1", boundaryAfter: .paragraph)
        let original = [Float](repeating: 0.2, count: 4410)
        var baseline = NarrationPlaybackCadence(model: .plus)
        var audio = original
        #expect(baseline.apply(to: &audio, unit: unit, sampleRate: 44_100) == 0)
        #expect(baseline.apply(to: &audio, unit: unit, sampleRate: 44_100, chapterBreak: true) == 0)
        #expect(audio == original)
        var cadence = NarrationPlaybackCadence(model: .plus, nativeTiming: true)
        #expect(cadence.apply(to: &audio, unit: unit, sampleRate: 44_100) == 0)
        audio = original
        #expect(cadence.apply(to: &audio, unit: unit, sampleRate: 44_100) == 19_845)
        #expect(Array(audio.suffix(original.count)) == original)
        cadence.reset(); audio = original
        #expect(cadence.apply(to: &audio, unit: unit, sampleRate: 44_100, chapterBreak: true) == 0)
        #expect(audio == original)
        audio = [Float](repeating: 0, count: 26_460) + original
        #expect(cadence.apply(to: &audio, unit: unit, sampleRate: 44_100) == 0)
    }

    @Test(arguments: NarrationModel.plus.supportedLanguageCodes, CTAssets.styles)
    func nativeBlendHasSameStylePairInEveryLanguage(_ language: String, _ style: String) throws {
        let id = "plus-\(style.lowercased())-\(language)-v1"
        let blend = try #require(NarrationDeliveryOptions(blendedVoice: true).nativeBlend(for: id))
        #expect(try blend.validated(primaryVoiceID: "dk-\(style.lowercased())-v1") != nil)
        #expect(CTAssets.voiceStyles[blend.secondaryVoiceID]?.first == style.first)
        #expect(blend.weight == 0.2)
        #expect(NarrationDeliveryOptions().nativeBlend(for: id) == nil)
    }

    @Test(arguments: NarrationModel.plus.supportedLanguageCodes)
    func sharedReadingCorrectionsSurviveRestoreAndSourceMapping(_ language: String) async throws {
        let lexicon = SpokenTextLexicon(entries: [.init(written: "XYZ", spoken: "Ada", language: language)])
        let restored = try JSONDecoder().decode(SpokenTextLexicon.self, from: JSONEncoder().encode(lexicon))
        #expect(restored.cacheIdentity == lexicon.cacheIdentity)
        #expect(restored.applyingReadings(to: "XYZ 42", language: language.uppercased() + "_ZZ") == "Ada 42")
        let source = "XYZ. " + (NarrationLanguage.sampleText(language) ?? "XYZ")
        let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "readings", chapterID: "one",
            narratorVoiceID: "plus-f1-\(language)-v1", language: language, lexicon: restored)
        #expect(plan.units.first?.synthesisText.hasPrefix("Ada") == true)
        for unit in plan.units { #expect(unit.text == (source as NSString).substring(with: unit.range)) }
        #expect(plan.units.allSatisfy { $0.nativeTextContext == nil })
    }

    @Test func nativeContextCacheIdentityIncludesActualGather() throws {
        var first = BookNarrationUnit(sourceText: "Hello.", sourceRange: .init(location: 0, length: 6), narratorID: "plus-f1-en-v1")
        var second = first
        first.nativeTextContext = try CTTextContext.bind(contextText: "Hello. Hello.", spokenRange: .init(location: 0, length: 6),
            spokenText: "Hello.", language: "en", modelFingerprint: "model", styleID: "F1")
        second.nativeTextContext = try CTTextContext.bind(contextText: "Hello. Hello.", spokenRange: .init(location: 7, length: 6),
            spokenText: "Hello.", language: "en", modelFingerprint: "model", styleID: "F1")
        #expect(NarrationModel.plus.renderIdentity(for: first) != NarrationModel.plus.renderIdentity(for: second))
        #expect(!NarrationModel.plus.supportsExpressiveDelivery)
    }
}
