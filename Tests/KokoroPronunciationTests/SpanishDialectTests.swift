// SPDX-License-Identifier: Apache-2.0 OR MIT
import Testing
@testable import KokoroPronunciation

struct SpanishDialectTests {
    @Test func rioplatenseIsAnExplicitProfile() {
        let p = SpanishPhonemizer()
        for word in ["llave", "lluvia", "calle", "ayer", "yo"] {
            #expect(p.phonemize(word, dialect: .argentina).contains("ʃ"), "\(word)")
            #expect(!p.phonemize(word, dialect: .latinAmerica).contains("ʃ"), "\(word)")
        }
        #expect(p.phonemize("cena", dialect: .spain).contains("θ"))
        #expect(!p.phonemize("cena", dialect: .argentina).contains("θ"))
        #expect(p.phonemize("hoy y mañana", dialect: .argentina).contains("i"))
    }
    @Test func voseoStressAndTextArePreserved() throws {
        let p = SpanishPhonemizer()
        for (word, tail) in [("tenés", "ˈnes"), ("podés", "ˈðes"), ("vení", "ˈni"), ("mirá", "ˈɾa")] {
            #expect(p.phonemize(word, dialect: .argentina).hasSuffix(tail), "\(word)")
        }
        let result = try PronunciationEngine().phonemize("Vos tenés la llave.", language: .spanish,
            options: .init(spanishDialect: .argentina, mixedLanguage: .disabled))
        #expect(result.normalizedText.contains("Vos"))
        #expect(!result.normalizedText.contains("tú"))
    }
    @Test func dialectsHaveIndependentStableIdentifiers() {
        #expect(SpanishDialect(rawValue: "spain") == .spain)
        #expect(SpanishDialect(rawValue: "latinAmerica") == .latinAmerica)
        #expect(SpanishDialect(rawValue: "argentina") == .argentina)
        #expect(SpanishDialect(languageTag: "es-Latn-AR") == .argentina)
        #expect(SpanishDialect(languageTag: "es-x-AR") == nil)
        #expect(SpanishDialect.argentina.languageTag == "es-AR")
    }
}
