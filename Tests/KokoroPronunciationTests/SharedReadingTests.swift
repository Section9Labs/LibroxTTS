import Foundation
import Testing
@testable import KokoroPronunciation

@Test func sharedReadingsMatchCanonicalAndContinuousScriptsWithoutCascading() throws {
    let lexicon = SpokenTextLexicon(entries: [
        .init(written: "Élodie", spoken: "Ela", language: "fr-FR"),
        .init(written: "太郎", spoken: "たろう", language: "ja"),
        .init(written: "重慶", spoken: "重庆", language: "zh"),
        .init(written: "XYZ", spoken: "Ada", language: "en"),
        .init(written: "XYZ", spoken: "Ignored", language: "en"),
        .init(written: "Ada", spoken: "Beta", language: "en")])
    #expect(lexicon.applyingReadings(to: "Élodie attend.".decomposedStringWithCanonicalMapping, language: "fr") == "Ela attend.")
    #expect(lexicon.applyingReadings(to: "太郎は言った。", language: "ja") == "たろうは言った。")
    #expect(lexicon.applyingReadings(to: "我住在重慶。", language: "zh") == "我住在重庆。")
    #expect(lexicon.applyingReadings(to: "XYZ Ada XYZ_1 AXYZ", language: "en") == "Ada Beta XYZ_1 AXYZ")
    #expect(lexicon.applyingReadings(to: "XYZ", language: "es") == "XYZ")
    let restored = try JSONDecoder().decode(SpokenTextLexicon.self, from: JSONEncoder().encode(lexicon))
    #expect(restored.cacheIdentity == lexicon.cacheIdentity)
    #expect(SpokenTextLexicon(entries: restored.entries.reversed()).cacheIdentity == lexicon.cacheIdentity)
}
