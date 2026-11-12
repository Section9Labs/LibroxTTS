import Foundation
import XCTest
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

final class PreparedNarrationTextTests: XCTestCase {
    func testEveryPrefixAndRestartAgainstFullNormalization() throws {
        for language in ["en", "es", "fr", "pt", "it"] {
            let lexicon = SpokenTextLexicon(entries: [.init(written: "Ada", spoken: "Aída 21", language: language)])
            for text in [
                "IV; chapter IX, Ada 21 libros; 1,234.50 dollars!",
                "€ 21,50, 2001-02-03; alle una, 12:05?",
                "e.g., 21 pages; i.e., 3.14, Ada!",
                "‘Cafe\u{301}’ 21, 31st; 3.1.2, 50 %!",
                "  II; IV, 12kg; USD 31; 21 casas,  21 páginas",
                "x; 0001, −12, +3.2; Ⅳ, １２３; 🙂!?"
            ] {
                let prepared = try XCTUnwrap(PreparedNarrationText(text, language: language, lexicon: lexicon, origin: 19))
                let source = text as NSString
                var ends = [0], offset = 0
                for c in text { offset += String(c).utf16.count; ends.append(offset) }
                for start in ends where start == 0 || (start > 0 && ";, ".utf16.contains(source.character(at: start - 1))) {
                    for end in ends where end >= start {
                        let range = NSRange(location: start, length: end - start)
                        let spoken = lexicon.text(source.substring(with: range), language: language)
                        let normalized = try? CTTokenizer.normalize(spoken, language: language, completeSentence: false)
                        let request = NSRange(location: start + 19, length: end - start)
                        for limit in [spoken.unicodeScalars.count - 1, spoken.unicodeScalars.count] {
                            if let actual = prepared.fits(request, model: .pocket, maximum: limit, allowEmptyPrefix: true) {
                                XCTAssertEqual(actual, spoken.unicodeScalars.count <= limit, "\(language) \(source.substring(with: range))")
                            }
                        }
                        if let actual = prepared.fits(request, model: .plus, maximum: 500, allowEmptyPrefix: false) {
                            XCTAssertEqual(actual, normalized.map { $0.unicodeScalars.count <= 500 } ?? false)
                        }
                    }
                }
            }
        }
    }

    func testLongContextualPlansRetainEveryPublicField() throws {
        for language in ["en", "es", "it", "fr", "pt"] {
            let lexicon = SpokenTextLexicon(entries: [.init(written: "Ada", spoken: "Aída", language: language)])
            let text = String(repeating: "Ada 21 libros, 31 casas; chapter IV, 12:05 y €21,50, ", count: 12) + "fin."
            for model in [NarrationModel.plus, .pocket] {
                let voice = model == .plus ? "plus-f1-\(language)-v1" : "pocket-caro_davy-\(language)-v1"
                let options = PocketTTSChunkingOptions(maximumUnitScalars: 128)
                let old = try ReferencePlanner07.plan(text, voiceID: voice, lexicon: lexicon, model: model, pocketChunking: options)
                let new = try TextNativeNarrationPlanner.plan(text, voiceID: voice, lexicon: lexicon, model: model, pocketChunking: options)
                XCTAssertEqual(old.count, new.count)
                for (a,b) in zip(old,new) {
                    XCTAssertEqual(a.text,b.text); XCTAssertEqual(a.range,b.range)
                    XCTAssertEqual(a.synthesisText,b.synthesisText); XCTAssertEqual(a.boundaryAfter,b.boundaryAfter)
                    XCTAssertEqual(String(reflecting:a.prosody),String(reflecting:b.prosody))
                    XCTAssertEqual(model.renderIdentity(for:a),model.renderIdentity(for:b))
                }
            }
        }
    }

    func testCrossBoundaryReadingsAndNewlinesAbstain() {
        for entry in [SpokenTextLexicon.Entry(written: "Ada, Lovelace", spoken: "Ada", language: "en"),
                      .init(written: "Ada", spoken: "IV\nII", language: "en")] {
            XCTAssertNil(PreparedNarrationText("Ada, Lovelace; 21", language: "en", lexicon: .init(entries: [entry]), origin: 0))
        }
        XCTAssertNil(PreparedNarrationText("Ada;\nIV", language: "en", lexicon: .init(), origin: 0))
    }
}
