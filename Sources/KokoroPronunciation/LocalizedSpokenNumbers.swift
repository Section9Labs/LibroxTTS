import Foundation

/// Locale-backed spoken cardinals for native languages outside the existing
/// phoneme normalizers. Unknown locales and malformed/ambiguous tokens abstain.
/// This never substitutes English when a locale cannot supply spoken words.
enum LocalizedSpokenNumbers {
    static func expand(_ source: String, language: String) -> String {
        guard NarrationLanguageRules.profiles[language] != nil else { return source }
        let locale = Locale(identifier: language)
        let words = NumberFormatter(); words.locale = locale; words.numberStyle = .spellOut
        let syntax = NumberFormatter(); syntax.locale = locale; syntax.numberStyle = .decimal
        let decimal = syntax.decimalSeparator ?? ".", grouping = syntax.groupingSeparator ?? ","
        let normalized = source.map { character -> String in
            if character.unicodeScalars.count == 1,
               character.unicodeScalars.first?.properties.numericType == .decimal,
               let number = character.wholeNumberValue { return String(number) }
            return String(character)
        }.joined()
        let pattern = #"(?<![\p{L}\p{M}\d_.,:/−+\-])([−+\-]?[0-9]+(?:[.,\x{066B}\x{066C}\x{00A0}\x{202F}][0-9]+)*)(?![\p{L}\p{M}\d_:/−+\-]|[.,\x{066B}\x{066C}][0-9])"#
        return TextReplacement.replace(normalized, pattern) { match in
            var token = match[1].replacingOccurrences(of: "−", with: "-")
            let negative = token.hasPrefix("-")
            // Keep explicit plus signs: many locales' formatters omit them.
            guard !token.hasPrefix("+") else { return match[0] }
            if negative { token.removeFirst() }
            let parts = token.components(separatedBy: decimal)
            guard parts.count <= 2 else { return match[0] }
            var integer = parts[0]
            if grouping == "\u{00A0}" || grouping == "\u{202F}" || grouping == " " {
                integer = integer.replacingOccurrences(of: "\u{00A0}", with: grouping)
                    .replacingOccurrences(of: "\u{202F}", with: grouping)
            }
            let groups = integer.components(separatedBy: grouping)
            guard groups.count == 1 || ((1...3).contains(groups[0].count)
                && groups.dropFirst().allSatisfy({ $0.count == 3 })) else { return match[0] }
            integer = groups.joined()
            guard !integer.isEmpty, integer.count <= 15,
                  integer.allSatisfy({ $0.isASCII && $0.isNumber }),
                  integer.count == 1 || integer.first != "0" else { return match[0] }
            if parts.count == 2 {
                guard (1...6).contains(parts[1].count), integer.count + parts[1].count <= 15, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return match[0] }
            }
            let value = (negative ? "-" : "") + integer + (parts.count == 2 ? "." + parts[1] : "")
            let number = NSDecimalNumber(string: value, locale: Locale(identifier: "en_US_POSIX"))
            guard number != .notANumber, let spoken = words.string(from: number),
                  spoken.contains(where: \.isLetter), !spoken.contains(where: \.isNumber) else { return match[0] }
            return spoken.replacingOccurrences(of: "\u{00AD}", with: "")
        }
    }
}
