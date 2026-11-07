import Foundation
import CryptoKit

/// The orthographic side of pronunciation preparation. Phoneme dictionaries stay
/// in PronunciationEngine; text-native models receive words, never Kokoro phones.
/// Callers can share reviewed name/abbreviation readings across every renderer.
public struct SpokenTextLexicon: Sendable, Codable {
    public struct Entry: Sendable, Codable, Equatable {
        public let written: String
        public let spoken: String
        public let language: String
        public init(written: String, spoken: String, language: String) {
            self.written = written; self.spoken = spoken; self.language = language
        }
    }
    public static let revision = "spoken-text-4"
    public let entries: [Entry]
    public let cacheIdentity: String
    private struct Compiled: Sendable {
        let regex: NSRegularExpression
        let readings: [String: String]
    }
    private let compiled: [String: Compiled]
    private enum CodingKeys: String, CodingKey { case entries }

    public init(entries: [Entry] = []) {
        var byLanguage: [String: [String: String]] = [:]
        // First entry wins: hosts place book corrections before global entries.
        for entry in entries {
            let language = Self.languageCode(entry.language)
            let written = entry.written.precomposedStringWithCanonicalMapping
            let spoken = entry.spoken.precomposedStringWithCanonicalMapping
            guard language.count == 2, !written.isEmpty,
                  !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  byLanguage[language]?[written] == nil else { continue }
            byLanguage[language, default: [:]][written] = spoken
        }
        self.entries = byLanguage.keys.sorted().flatMap { language in
            byLanguage[language]!.keys.sorted().map {
                Entry(written: $0, spoken: byLanguage[language]![$0]!, language: language)
            }
        }
        var compiled: [String: Compiled] = [:]
        for (language, readings) in byLanguage {
            let alternatives = readings.keys.sorted {
                $0.count == $1.count ? $0 < $1 : $0.count > $1.count
            }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            // Japanese/Chinese text has no reliable whitespace word boundary.
            // Explicit user phrases match literally within that script; Latin
            // identifiers still retain their boundaries.
            let word = ["ja", "zh"].contains(language) ? "A-Za-z0-9_" : "\\p{L}\\p{M}\\d_"
            let pattern = "(?<![" + word + "])(?:" + alternatives + ")(?![" + word + "])"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                compiled[language] = Compiled(regex: regex, readings: readings)
            }
        }
        self.compiled = compiled
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Encoding these string-only entries cannot fail.
        let data = try! encoder.encode(self.entries)
        cacheIdentity = Self.revision + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(entries: try values.decode([Entry].self, forKey: .entries))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries, forKey: .entries)
    }
    private static func languageCode(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    public func applyingReadings(to source: String, language: String) -> String {
        guard let rules = compiled[Self.languageCode(language)] else { return source }
        // NFC is a private synthesis representation. Display/highlight offsets
        // remain in the original BookNarrationUnit text, never this copy.
        let canonical = source.precomposedStringWithCanonicalMapping
        var result = canonical
        for match in rules.regex.matches(in: canonical, range: NSRange(canonical.startIndex..., in: canonical)).reversed() {
            guard let range = Range(match.range, in: result), let original = Range(match.range, in: canonical),
                  let reading = rules.readings[String(canonical[original])] else { continue }
            result.replaceSubrange(range, with: reading)
        }
        return result
    }

    public func text(_ source: String, language: String) -> String {
        let language = Self.languageCode(language)
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
