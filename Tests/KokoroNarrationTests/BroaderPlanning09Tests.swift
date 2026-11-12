import Foundation
import XCTest
import KokoroCatalog
import KokoroPronunciation
import LibroxCTNative
@testable import KokoroNarration

final class BroaderPlanning09Tests: XCTestCase {
    func testQuotePrefixesPreserveScalarBudgetsAndRewritingFallbacks() throws {
        for language in ["en","es","fr","pt","it"] {
            for text in ["«L'amica tornò,» disse lei.","“Ada's café,” she said.","‘La porta’ era aperta."] {
                let budget = try XCTUnwrap(PlainNarrationBudget(text,language:language,lexicon:.init(),origin:17))
                let ns = text as NSString
                var offsets = [0], n = 0
                for c in text { n += String(c).utf16.count; offsets.append(n) }
                for a in offsets { for b in offsets where b >= a {
                    let spoken = SpokenTextLexicon().text(ns.substring(with:NSRange(location:a,length:b-a)),language:language)
                    let range = NSRange(location:17+a,length:b-a)
                    XCTAssertEqual(budget.fits(range,model:.pocket,maximum:spoken.unicodeScalars.count,allowEmptyPrefix:true),true)
                    XCTAssertEqual(budget.fits(range,model:.pocket,maximum:spoken.unicodeScalars.count-1,allowEmptyPrefix:true),false)
                    let normalized = try? CTTokenizer.normalize(spoken,language:language,completeSentence:false)
                    XCTAssertEqual(budget.fits(range,model:.plus,maximum:2400,allowEmptyPrefix:false),normalized != nil)
                } }
                XCTAssertNil(budget.fits(NSRange(location:0,length:20),model:.pocket,maximum:2400,allowEmptyPrefix:true))
            }
        }
        for text in ["\"“hello", "‘'hello", "hello 'word", "Alle una", "xalle una", "capítulo I", "capi\u{301}tulo I"] {
            let language = text.contains("una") ? "it" : "es"
            XCTAssertNil(PlainNarrationBudget(text,language:language,lexicon:.init()),text)
        }
    }
    func testMixedBooksAndDictionaryReadingsMatchOriginalPrefixAlgorithm() throws {
        let long = String(repeating:"La puerta estaba abierta y nadie regresaba, ",count:20)
        let lexicon = SpokenTextLexicon(entries:[.init(written:"Ada",spoken:"Aída",language:"es")])
        for language in ["es","it","fr","pt","en"] {
            for model in [NarrationModel.plus,.pocket] {
                for text in ["En 2024, Ada volvió.\n\n«"+long+"fin.»", long+"fin.","Ada volvió. "+long+"fin.","alle una, "+long+"fin."] {
                    let voice = model == .plus ? "plus-f1-\(language)-v1" : "pocket-caro_davy-\(language)-v1"
                    let options = PocketTTSChunkingOptions(maximumUnitScalars:128)
                    let old = try ReferencePlanner07.plan(text,voiceID:voice,lexicon:lexicon,model:model,pocketChunking:options)
                    let new = try TextNativeNarrationPlanner.plan(text,voiceID:voice,lexicon:lexicon,model:model,pocketChunking:options)
                    XCTAssertEqual(old.count,new.count)
                    for (a,b) in zip(old,new) {
                        XCTAssertEqual(a.text,b.text); XCTAssertEqual(a.range,b.range)
                        XCTAssertEqual(a.synthesisText,b.synthesisText); XCTAssertEqual(a.boundaryAfter,b.boundaryAfter)
                        XCTAssertEqual(String(reflecting:a.prosody),String(reflecting:b.prosody))
                        XCTAssertEqual(model.renderIdentity(for:a),model.renderIdentity(for:b))
                    }
                }
            }
        }
    }

    func testQuotedPlusPrefixesAtTokenizerLimit() throws {
        for language in ["en", "es", "fr", "pt", "it"] {
            for quote in ["\"", "'", "“", "‘", "«"] {
                for length in 480...505 {
                    let text = quote + String(repeating: "a", count: length) + quote
                    let budget = try XCTUnwrap(PlainNarrationBudget(text, language: language, lexicon: .init()))
                    let normalized = try? CTTokenizer.normalize(text, language: language, completeSentence: false)
                    XCTAssertEqual(budget.fits(NSRange(location: 0, length: text.utf16.count), model: .plus,
                                               maximum: 2400, allowEmptyPrefix: false), normalized.map { $0.unicodeScalars.count <= 500 } ?? false,
                                   "\(language) \(quote) \(length)")
                }
            }
        }
    }
}
