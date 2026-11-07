import Foundation
import Testing
import KokoroPronunciation
@testable import KokoroNarration

@Test(arguments: [
    ("en", "Anna waited. “You came,” she said. The road was empty.", "“You came,”"),
    ("es", "🌙 Lucía esperó. «Has vuelto», dijo. El camino estaba vacío.", "«Has vuelto»"),
    ("es", "Lucía esperó. «Sí», dijo. Nadie habló.", "«Sí»"),
    ("en", "She waited.  Yes, I did.  He stopped.", " Yes, I did. ")
])
func nativeContextGatherPreservesExactNormalizedInput(_ language: String, _ text: String, _ spoken: String) throws {
    let source = text.decomposedStringWithCanonicalMapping
    let unit = spoken.decomposedStringWithCanonicalMapping
    let range = (source as NSString).range(of: unit)
    let binding = try NarrationTextContext.bind(contextText: source, spokenRange: range, spokenText: unit,
        language: language, modelFingerprint: "test-assets", styleID: "F1")
    let context = Array(binding.normalizedContext.unicodeScalars)
    let gathered = String(String.UnicodeScalarView(binding.gatherIndices.map { context[$0] }))
    #expect(gathered == binding.normalizedSpoken)
    #expect(!binding.isIdentity)
    #expect(NarrationTextContext.validates(binding, spokenText: unit, language: language, modelFingerprint: "test-assets", styleID: "F1"))
    #expect(!NarrationTextContext.validates(binding, spokenText: unit, language: language, modelFingerprint: "test-assets", styleID: "M1"))
}

@Test func repeatedWordsUseSourceRangeNotFirstTextMatch() throws {
    let text = "“Yes,” Anna said. “Yes,” John replied. They waited."
    let first = (text as NSString).range(of: "“Yes,”")
    let second = (text as NSString).range(of: "“Yes,”", options: .backwards)
    let a = try NarrationTextContext.bind(contextText: text, spokenRange: first, spokenText: "“Yes,”", language: "en", modelFingerprint: "a", styleID: "F1")
    let b = try NarrationTextContext.bind(contextText: text, spokenRange: second, spokenText: "“Yes,”", language: "en", modelFingerprint: "a", styleID: "F1")
    #expect(a.gatherIndices != b.gatherIndices)
    #expect(a.normalizedSpoken == b.normalizedSpoken)
    #expect(a.renderCacheKey != b.renderCacheKey)
    #expect(a.featureCacheKey == b.featureCacheKey) // The same full-context features can be gathered twice.
}

@Test func normalizationMismatchNeverGuessesMissingTokenAlignment() throws {
    let text = "She wrote a . Then she waited."
    // Whole normalization removes this cross-boundary space; inserted markers
    // would prevent that. The candidate must fall back to ordinary native DK.
    let range = (text as NSString).range(of: ". Then")
    #expect(throws: NarrationTextContext.BindingError.self) {
        try NarrationTextContext.bind(contextText: text, spokenRange: range, spokenText: ". Then", language: "en", modelFingerprint: "a", styleID: "F1")
    }
}

@Test func contextCacheSeparatesModelVoiceLanguageAndText() throws {
    let text = "She said yes. He smiled."
    func binding(_ source: String = text, _ model: String = "a", _ style: String = "F1", _ language: String = "en") throws -> NarrationTextContext.Binding {
        try NarrationTextContext.bind(contextText: source, spokenRange: (source as NSString).range(of: "yes"), spokenText: "yes", language: language, modelFingerprint: model, styleID: style)
    }
    let base = try binding()
    #expect(try binding(text, "b").featureCacheKey != base.featureCacheKey)
    #expect(try binding(text, "a", "M1").featureCacheKey != base.featureCacheKey)
    #expect(try binding(text, "a", "F1", "es").featureCacheKey != base.featureCacheKey)
    #expect(try binding("She said yes. He frowned.").featureCacheKey != base.featureCacheKey)
    let identity = try NarrationTextContext.bind(contextText: "Hello.", spokenRange: NSRange(location: 0, length: 6), spokenText: "Hello.", language: "en", modelFingerprint: "a", styleID: "F1")
    #expect(identity.isIdentity)
}

@Test func nativeCharacterContextSurvivesDictionaryExpansion() async throws {
    let source = "Anna opened the door. “I waited 12 years,” John said. Anna smiled."
    let lexicon = SpokenTextLexicon(entries: [.init(written: "John", spoken: "Jon", language: "en")])
    let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "ctx", chapterID: "1",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true, lexicon: lexicon)
    let index = try #require(plan.units.firstIndex { $0.role == .dialogue })
    let binding = try NarrationTextContext.surrounding(plan.units, index: index, source: source,
        language: "en", modelFingerprint: "a", styleID: "M1")
    #expect(binding.spokenText.contains("twelve"))
    #expect(binding.contextText.contains("Jon"))
    #expect(binding.contextText.contains("Anna opened"))
    #expect(binding.contextText.contains("Anna smiled"))
    #expect(!binding.isIdentity)
    #expect(source.contains("12"))
    #expect(NarrationTextContext.validates(binding, spokenText: plan.units[index].synthesisText,
        language: "en", modelFingerprint: "a", styleID: "M1"))
}

@Test func nativeContextBoundsAndParagraphIsolationAreEnforced() async throws {
    let source = "Anna waited.\n\n“Hello,” John said."
    let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "ctx", chapterID: "2",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true)
    let index = try #require(plan.units.firstIndex { $0.role == .dialogue })
    let bound = try NarrationTextContext.surrounding(plan.units, index: index, source: source,
        language: "en", modelFingerprint: "a", styleID: "M1")
    #expect(!bound.contextText.contains("Anna"))
    let huge = String(repeating: "hello ", count: 100)
    #expect(throws: NarrationTextContext.BindingError.self) {
        try NarrationTextContext.bind(contextText: huge, spokenRange: NSRange(location: 0, length: 5), spokenText: "hello", language: "en", modelFingerprint: "a", styleID: "F1")
    }
    #expect(throws: NarrationTextContext.BindingError.self) {
        try NarrationTextContext.bind(contextText: "e\u{301}", spokenRange: NSRange(location: 0, length: 1), spokenText: "e", language: "es", modelFingerprint: "a", styleID: "F1")
    }
}
