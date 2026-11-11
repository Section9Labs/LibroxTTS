// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
import Foundation

public enum TextNormalizer {
    public static func normalize(_ text: String, language: PronunciationLanguage) -> String {
        let roman = RomanNumerals.expand(text, language: language)
        var result = StructuredNumbers.expand(NarrativeText.normalize(roman), language: language)
        // Misaki already has context-aware English number/currency expansion.
        guard language != .english else { return result }
        // Structured readings may consume all numbers. The remaining rule only
        // matches decimal digits; preserve all earlier narrative/Roman handling.
        guard result.unicodeScalars.contains(where: {
            $0.properties.numericType != nil || CharacterSet.decimalDigits.contains($0)
        }) else { return result }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = language.locale
        func spell(_ number: String) -> String {
            let value = NSDecimalNumber(string: number, locale: Locale(identifier: "en_US_POSIX"))
            guard value != .notANumber else { return number }
            return (formatter.string(from: value) ?? number).replacingOccurrences(of: "\u{00AD}", with: "").replacingOccurrences(of: "〇", with: language == .chinese ? "零" : "ゼロ")
        }
        let commaDecimal = [.spanish, .french, .italian, .portuguese].contains(language)
        // Match the entire numeric token, then validate grouping. Do not partially
        // reinterpret version numbers, identifiers, dates, or malformed groups.
        let cjk = language == .japanese || language == .chinese
        let boundaryLetters = cjk ? "A-Za-z" : #"\p{L}"#
        let pattern = "(?<![" + boundaryLetters + #"\d/:−-])[−-]?\d+(?:[.,\x{00A0}\x{202F}]\d+)*(?!["# + boundaryLetters + #"\d/:−-])"#
        result = replacing(result, pattern: pattern) { groups in
            var token = groups[0]
            let negative = token.first == "-" || token.first == "−"
            if negative { token.removeFirst() }
            let decimal: Character = commaDecimal ? "," : "."
            let grouping: Character = commaDecimal ? "." : ","
            let parts = token.split(separator: decimal, omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return groups[0] }
            let integerText = parts[0].replacingOccurrences(of: "\u{00A0}", with: String(grouping)).replacingOccurrences(of: "\u{202F}", with: String(grouping))
            let integerGroups = integerText.split(separator: grouping, omittingEmptySubsequences: false)
            let westernGroups = integerGroups[0].count <= 3 && integerGroups.dropFirst().allSatisfy { $0.count == 3 }
            let indianGroups = language == .hindi && integerGroups[0].count <= 2 && integerGroups.last?.count == 3 && integerGroups.dropFirst().dropLast().allSatisfy { $0.count == 2 }
            guard integerGroups.count == 1 || westernGroups || indianGroups else { return groups[0] }
            guard parts.count == 1 || parts[1].allSatisfy(\.isNumber) else { return groups[0] }
            let integer = integerGroups.joined()
            // NumberFormatter loses exactness on very long numbers. Preserve and
            // diagnose them instead of inventing a rounded spoken value.
            guard integer.count <= 15 else { return groups[0] }
            var spoken = spell(integer)
            if parts.count == 2 {
                let point = commaDecimal ? (language == .italian ? " virgola " : language == .portuguese ? " vírgula " : language == .french ? " virgule " : " coma ") : (language == .hindi ? " दशमलव " : language == .japanese ? "点" : "点")
                spoken += point + parts[1].map { spell(String($0)) }.joined(separator: language == .japanese || language == .chinese ? "" : " ")
            }
            if negative { spoken = ["es":"menos ","fr":"moins ","it":"meno ","pt":"menos ","hi":"ऋण ","ja":"マイナス","zh":"负"][language.rawValue]! + spoken }
            return spoken
        }
        return result
    }

    private static func replacing(_ text: String, pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = CompiledTextRules.expression(pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: transform(groups)) }
        }
        return result
    }
}
