import XCTest
@testable import PronunciationEnglish

final class CompiledLexiconTests: XCTestCase {
    func testCanonicalKeyEqualityMatchesSwiftDictionary() throws {
        let archive = try XCTUnwrap(CompiledLexicon(name: "us_gold"))
        XCTAssertEqual(archive.value(for: "K"), archive.value(for: "K"))
        XCTAssertNotNil(archive.value(for: "K"))
    }
    func testMissingCorruptAndChangedSourceCannotUseDerivedArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>librox.lexicon.fixture</string></dict></plist>".utf8)
            .write(to:root.appendingPathComponent("Contents/Info.plist"))
        let original = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"us_gold",withExtension:"json")))
        let archive = try Data(contentsOf:XCTUnwrap(Bundle.module.url(forResource:"us_gold",withExtension:"lxt")))
        let sourceURL = resources.appendingPathComponent("us_gold.json"), archiveURL = resources.appendingPathComponent("us_gold.lxt")
        try original.write(to:sourceURL); try archive.write(to:archiveURL)
        let bundle = try XCTUnwrap(Bundle(url:root))
        XCTAssertNotNil(CompiledLexicon(name:"us_gold",bundle:bundle))
        try Data("{}".utf8).write(to:sourceURL)
        XCTAssertNil(CompiledLexicon(name:"us_gold",bundle:bundle))
        try original.write(to:sourceURL); try Data("bad archive".utf8).write(to:archiveURL)
        XCTAssertNil(CompiledLexicon(name:"us_gold",bundle:bundle))
        try FileManager.default.removeItem(at:archiveURL)
        XCTAssertNil(CompiledLexicon(name:"us_gold",bundle:bundle))
    }
    func testEveryCompiledEntryMatchesOriginalLoaderAndValidation() throws {
        XCTAssertGreaterThan(try Lexicon.verifyCompiledDictionaries(), 700_000)
    }
}
