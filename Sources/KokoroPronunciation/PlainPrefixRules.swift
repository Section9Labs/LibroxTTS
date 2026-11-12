import Foundation

extension TextNormalizer {
    /// A conservative proof domain for counting NFC/NFKD prefixes without
    /// evaluating every rule again. New lexical normalization rules must update
    /// this gate and its prefix-differential tests. Other text uses the full path.
    package static func permitsPlainPrefixCounting(_ text: String, language: PronunciationLanguage) -> Bool {
        guard [.english, .spanish, .french, .portuguese, .italian].contains(language) else { return false }
        guard !text.contains("..."), !text.contains("e.g.,"), !text.contains("i.e.,") else { return false }
        if language == .italian, text.contains("alle una") || text.contains("Alle una") { return false }
        let roman = Set("IVXLCDM".unicodeScalars)
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let letter = (65...90).contains(value) || (97...122).contains(value)
                || ((0xC0...0x24F).contains(value) && CharacterSet.letters.contains(scalar))
            let mark = (0x300...0x36F).contains(value)
            guard letter || mark || " .,;:!?-\"'‘’“”«»".unicodeScalars.contains(scalar) else { return false }
            // These quote rewrites are one scalar each. Exclude combinations
            // that CT collapses after straightening quotes, including mixed forms.
            let normalized: Unicode.Scalar = "‘’".unicodeScalars.contains(scalar) ? "'"
                : "“”«»".unicodeScalars.contains(scalar) ? "\"" : scalar
            if (normalized == "'" || normalized == "\""), previous == normalized { return false }
            // CT whitespace/punctuation rewriting is deliberately excluded.
            if previous == " ", normalized == " " || ".,;:!?'".unicodeScalars.contains(normalized) { return false }
            // Any source substring might become the start of a split unit.
            // Reject every possible uppercase Roman heading prefix.
            if let previous, roman.contains(previous), roman.contains(scalar) { return false }
            previous = normalized
        }
        if let labels = RomanNumerals.labels[language] {
            // No left boundary: a long unbroken word can be split just before a
            // label suffix. Use the normalizer's own ICU case-insensitive rules.
            guard let regex = CompiledTextRules.expression("(?i)(?:" + labels + ")[ \\t]+") else { return false }
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return false }
        }
        return true
    }
}
