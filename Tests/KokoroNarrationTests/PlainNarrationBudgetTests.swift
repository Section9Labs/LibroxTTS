import XCTest
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

final class PlainNarrationBudgetTests: XCTestCase {
    func testSupportedPrefixesAndInteriorSlicesMatchFullNormalization() throws {
        let text = " La puerta, e\u{301}l volvió; cafe\u{301} y ſal? Ada volvió. "
        let source = text as NSString
        var offsets = [0], offset = 0
        for c in text { offset += String(c).utf16.count; offsets.append(offset) }
        for language in ["en", "es", "fr", "pt"] {
            let budget = try XCTUnwrap(PlainNarrationBudget(text, language: language, lexicon: .init()))
            for start in offsets {
                for end in offsets where end >= start {
                    let range = NSRange(location: start, length: end - start)
                    let spoken = SpokenTextLexicon().text(source.substring(with: range), language: language)
                    for maximum in [max(0, spoken.unicodeScalars.count - 1), spoken.unicodeScalars.count] {
                        XCTAssertEqual(budget.fits(range, model: .pocket, maximum: maximum, allowEmptyPrefix: true),
                                       spoken.unicodeScalars.count <= maximum)
                    }
                    for empty in [false, true] {
                        let expected: Bool
                        do { expected = try CTTokenizer.normalize(spoken, language: language, completeSentence: false).unicodeScalars.count <= 500 }
                        catch CTError.emptyText { expected = empty }
                        catch { expected = false }
                        XCTAssertEqual(budget.fits(range, model: .plus, maximum: 2400, allowEmptyPrefix: empty), expected)
                    }
                }
            }
        }
    }

    func testLatinCompatibilityAndCombiningFormsAtExactPlusBudget() throws {
        let scalars = (0xC0...0x24F).compactMap(Unicode.Scalar.init).filter(CharacterSet.letters.contains)
            + ["\u{0301}", "\u{0308}", "\u{0344}", "\u{0345}"]
        for scalar in scalars {
            for padding in 488...492 {
                let text = String(repeating: "a", count: padding) + String(scalar) + "x"
                let budget = try XCTUnwrap(PlainNarrationBudget(text, language: "es", lexicon: .init()))
                let spoken = SpokenTextLexicon().text(text, language: "es")
                let count = try CTTokenizer.normalize(spoken, language: "es", completeSentence: false).unicodeScalars.count
                XCTAssertEqual(budget.fits(NSRange(location: 0, length: text.utf16.count), model: .plus,
                    maximum: 2400, allowEmptyPrefix: false), count <= 500, "U+\(String(scalar.value, radix: 16)), \(padding)")
            }
        }
    }

    func testContextualAndUnsupportedTextAlwaysUsesGeneralPath() {
        for text in ["chapter v", "apart v", "ſcene v", "MIXed words", "21 libros", "a  b", "a , b",
                     "e.g., home", "i.e., home", "a...b", "a .b", "a\n\nb", "alle una", "第IV章", "hello 😀"] {
            let language = text == "alle una" ? "it" : "en"
            XCTAssertNil(PlainNarrationBudget(text, language: language, lexicon: .init()), text)
        }
        let lexicon = SpokenTextLexicon(entries: [.init(written: "QX", spoken: "a longer reading", language: "en")])
        XCTAssertNil(PlainNarrationBudget("ordinary text", language: "en", lexicon: lexicon))
    }

    func testCompletePlansMatchFrozen07Algorithm() throws {
        var seed: UInt64 = 7
        let words = ["La", "puerta", "abierta", "Ada", "volvió", "cafe\u{301}", "mañana", "y", "nadie", "esperaba"]
        let generated = (0..<105).map { index -> String in
            seed = seed &* 6364136223846793005 &+ 1
            return words[Int(seed % UInt64(words.count))] + (index % 13 == 0 ? "," : "")
        }.joined(separator: " ")
        for language in ["en", "es", "fr", "pt"] {
            for model in [NarrationModel.plus, .pocket] {
                let voice = model == .plus ? "plus-f1-\(language)-v1" : "pocket-caro_davy-\(language)-v1"
                for text in [String(repeating: "La puerta estaba abierta y nadie regresaba, ", count: 17),
                             String(repeating: "Él volvió; ella esperaba, ", count: 24) + "fin.", generated] {
                    let options = PocketTTSChunkingOptions(maximumUnitScalars: 128)
                    let old = try ReferencePlanner07.plan(text, voiceID: voice, model: model, pocketChunking: options)
                    let new = try TextNativeNarrationPlanner.plan(text, voiceID: voice, model: model, pocketChunking: options)
                    XCTAssertEqual(new.count, old.count)
                    for (a, b) in zip(old, new) {
                        XCTAssertEqual(a.text, b.text); XCTAssertEqual(a.range, b.range)
                        XCTAssertEqual(a.synthesisText, b.synthesisText); XCTAssertEqual(a.voiceID, b.voiceID)
                        XCTAssertEqual(a.phonemes, b.phonemes); XCTAssertEqual(a.boundaryAfter, b.boundaryAfter)
                        XCTAssertEqual(a.role, b.role); XCTAssertEqual(a.expression, b.expression)
                        XCTAssertEqual(a.speakerID, b.speakerID)
                        XCTAssertEqual(String(reflecting: a.prosody), String(reflecting: b.prosody))
                        XCTAssertEqual(a.pocketChunking?.cacheIdentity, b.pocketChunking?.cacheIdentity)
                        XCTAssertEqual(model.renderIdentity(for: a), model.renderIdentity(for: b))
                    }
                }
            }
        }
    }
}
