import XCTest
@testable import PronunciationEnglish

final class CompiledLexiconTests: XCTestCase {
    func testCanonicalKeyEqualityMatchesSwiftDictionary() throws {
        let archive = try XCTUnwrap(CompiledLexicon(name: "us_gold"))
        XCTAssertEqual(archive.value(for: "K"), archive.value(for: "K"))
        XCTAssertNotNil(archive.value(for: "K"))
    }
    func testEveryCompiledEntryMatchesOriginalLoaderAndValidation() throws {
        XCTAssertGreaterThan(try Lexicon.verifyCompiledDictionaries(), 700_000)
    }
}
