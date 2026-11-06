import Testing
@testable import LibroxCTNative

@Test func normalizationRetainsSpanishAndContext() throws {
    #expect(try CTTokenizer.normalize("  Él—dijo: “sí” 😊  ", language: "es") == "<es>E\u{301}l-dijo: \"si\u{301}\"</es>")
    #expect(try CTTokenizer.normalize("She waited. He came back.", language: "en") == "<en>She waited. He came back.</en>")
    #expect(throws: CTError.self) { try CTTokenizer.normalize("... 😊", language: "en") }
    #expect(throws: CTError.self) { try CTTokenizer.normalize("Bonjour", language: "fr") }
}
