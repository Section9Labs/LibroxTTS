import Foundation
import PronunciationEnglish

/// Orthographic readings for native text models, using the same number-word
/// implementation as the English phoneme frontend. Consume complete numeric
/// tokens so malformed grouping, versions and identifiers cannot be read in parts.
enum EnglishSpokenNumbers {
    static func expand(_ source: String) -> String {
        let pattern = #"(?<![\p{L}\p{M}\d_.,:/−+\-])([−+\-]?(?:[0-9]+(?:[.,][0-9]+)*|\.[0-9]+))((?i:st|nd|rd|th))?(?![\p{L}\p{M}\d_:/−+\-]|[.,][0-9])"#
        return TextReplacement.replace(source, pattern) { groups in
            var token = groups[1]
            let sign = token.first
            if sign == "-" || sign == "−" || sign == "+" { token.removeFirst() }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return groups[0] }
            let integerGroups = parts[0].split(separator: ",", omittingEmptySubsequences: false)
            guard integerGroups.count == 1 || ((1...3).contains(integerGroups[0].count)
                && integerGroups.dropFirst().allSatisfy({ $0.count == 3 })) else { return groups[0] }
            let integer = integerGroups.joined()
            guard integer.count <= 15,
                  integer.count < 2 || integer.first != "0",
                  !integer.isEmpty || parts.count == 2,
                  parts.count == 1 || parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return groups[0] }
            let suffix = groups[2].lowercased()
            var reading: String
            if !suffix.isEmpty {
                guard parts.count == 1, let number = Int64(integer) else { return groups[0] }
                let expected = (11...13).contains(number % 100) ? "th"
                    : [1: "st", 2: "nd", 3: "rd"][number % 10] ?? "th"
                guard suffix == expected else { return groups[0] }
                reading = NumberToWords.ordinal(number)
            } else {
                reading = integer.isEmpty ? "" : NumberToWords.cardinal(integer) ?? integer
                if parts.count == 2 {
                    reading += (reading.isEmpty ? "" : " ") + "point "
                        + parts[1].map { NumberToWords.cardinal(String($0)) ?? String($0) }.joined(separator: " ")
                }
            }
            return (sign == "-" || sign == "−" ? "minus " : sign == "+" ? "plus " : "") + reading
        }
    }
}
