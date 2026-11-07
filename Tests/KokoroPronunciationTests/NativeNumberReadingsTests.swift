import Testing
@testable import KokoroPronunciation

struct NativeNumberReadingsTests {
    @Test(arguments: [
        ("There were 42.", "There were forty-two."),
        ("It was 1,234.05 degrees.", "It was one thousand two hundred thirty-four point zero five degrees."),
        ("The change was -0.05 percent.", "The change was minus zero point zero five percent."),
        ("Add +12 and .5.", "Add plus twelve and point five."),
        ("Her 101st and 112th attempts.", "Her one hundred first and one hundred twelfth attempts."),
        ("The value was 3.14, then 42!", "The value was three point one four, then forty-two!"),
        ("It cost $12.50 at 15:30.", "It cost twelve dollars and fifty cents at fifteen thirty.")
    ])
    func nativeEnglishUsesSharedNumberWords(_ source: String, _ expected: String) {
        #expect(SpokenTextLexicon().text(source, language: "en") == expected)
    }

    @Test(arguments: ["version 1.2.3", "ISBN 978-84-1234", "03/04/2026", "25:30",
                      "1,23,456", "00123", "A123", "123ABC", "id_123", "1234567890123456", "101th"])
    func ambiguousNativeNumbersStayIntact(_ source: String) {
        #expect(SpokenTextLexicon().text(source, language: "en") == source)
    }
}
