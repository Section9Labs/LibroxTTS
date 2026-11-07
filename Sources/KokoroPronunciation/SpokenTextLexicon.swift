import Foundation

/// The orthographic side of pronunciation preparation. Phoneme dictionaries stay
/// in PronunciationEngine; text-native models receive words, never Kokoro phones.
/// Callers can share reviewed name/abbreviation readings across every renderer.
public struct SpokenTextLexicon: Sendable {
    public struct Entry: Sendable {
        public let written: String
        public let spoken: String
        public let language: String
        public init(written: String, spoken: String, language: String) {
            self.written = written; self.spoken = spoken; self.language = language
        }
    }
    public static let revision = "spoken-text-3"
    private let entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }

    public func applyingReadings(to source: String, language: String) -> String {
        // Match against the source once. A replacement never triggers another
        // entry and longer names take priority over their individual words.
        let applicable = entries.filter { $0.language == language && !$0.written.isEmpty && !$0.spoken.isEmpty }
            .sorted { $0.written.count > $1.written.count }
        guard !applicable.isEmpty else { return source }
        let pattern = "(?<![\\p{L}\\p{M}\\d])(?:" + applicable.map {
            NSRegularExpression.escapedPattern(for: $0.written)
        }.joined(separator: "|") + ")(?![\\p{L}\\p{M}\\d])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result), let original = Range(match.range, in: source),
                  let entry = applicable.first(where: { $0.written == source[original] }) else { continue }
            result.replaceSubrange(range, with: entry.spoken)
        }
        return result
    }

    public func text(_ source: String, language: String) -> String {
        var text = applyingReadings(to: source, language: language)
        if let language = PronunciationLanguage(rawValue: language) {
            text = TextNormalizer.normalize(text, language: language)
        } else {
            text = LocalizedSpokenNumbers.expand(text, language: language)
        }
        // English's shared normalizer leaves general numbers to its G2P.
        // Native text gets the same number words without passing phonemes.
        if language == "en" {
            text = EnglishSpokenNumbers.expand(text)
        }
        return text
    }
}
