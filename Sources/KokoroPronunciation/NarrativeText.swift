// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
import Foundation

/// Written structure is a prosody cue, not an instruction to invent emphasis.
enum NarrativeText {
    static func normalize(_ input: String) -> String {
        var text = input.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for (source, target) in [("«", "“"), ("»", "”"), ("「", "“"), ("」", "”"),
                                 ("『", "“"), ("』", "”")] {
            text = text.replacingOccurrences(of: source, with: target)
        }
        text = text.replacingOccurrences(of: #"\.{3,}|…{2,}"#, with: "…", options: .regularExpression)
        // A soft line wrap is not a sentence boundary. A blank line is, but an
        // existing question/exclamation/ellipsis must retain its own contour.
        text = TextReplacement.replace(text, #"([^\s])([ \t]*\n){2,}[ \t]*"#) { g in
            let terminal = ".!?…。！？।॥,:;，、：；—–“”\"'’)]}"
            return g[1] + (terminal.contains(g[1]) ? " " : ". ")
        }
        return text
    }
}

enum TextReplacement {
    static func replace(_ text: String, _ pattern: String, transform: ([String]) -> String) -> String {
        guard let regex = CompiledTextRules.expression(pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            if let range = Range(match.range, in: result) { result.replaceSubrange(range, with: transform(groups)) }
        }
        return result
    }
}

/// Interpret canonical Roman notation only in a numeric context. In particular,
/// the English pronoun I and ordinary words such as MIX are not global numbers.
enum RomanNumerals {
    static func value(_ text: String) -> Int? {
        let value = text.uppercased()
        guard !value.isEmpty, value.count <= 15,
              value.range(of: #"^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$"#, options: .regularExpression) != nil else { return nil }
        let values: [Character: Int] = ["I":1,"V":5,"X":10,"L":50,"C":100,"D":500,"M":1000]
        var total = 0, previous = 0
        for c in value.reversed() {
            guard let n = values[c] else { return nil }
            total += n < previous ? -n : n
            previous = max(previous, n)
        }
        return total
    }

    static func expand(_ input: String, language: PronunciationLanguage) -> String {
        // Only compatibility-normalize the Unicode Roman numeral block.
        var text = input.unicodeScalars.map { (0x2160...0x217F).contains($0.value)
            ? String($0).precomposedStringWithCompatibilityMapping : String($0) }.joined()
        let labels: [PronunciationLanguage: String] = [
            .english:"chapter|book|volume|part|act|scene", .spanish:"capítulo|capitulo|libro|tomo|volumen|parte|siglo|acto|escena",
            .french:"chapitre|livre|tome|volume|partie|acte|scène", .italian:"capitolo|libro|tomo|volume|parte|atto|scena",
            .portuguese:"capítulo|capitulo|livro|tomo|volume|parte|século|ato|cena", .hindi:"अध्याय|भाग|खंड"]
        if let labels = labels[language] {
            text = TextReplacement.replace(text, "(?i)(?<![\\p{L}\\p{M}])((?:" + labels + #")[ \t]+)([IVXLCDM]+)(?![\p{L}\p{M}\d])"#) { g in
                guard let number = value(g[2]) else { return g[0] }
                return g[1] + String(number)
            }
        }
        if language == .japanese || language == .chinese {
            text = TextReplacement.replace(text, #"(第)[ \t]*([IVXLCDM]+)[ \t]*(章|巻|卷|部|节|節)"#) { g in
                guard let number = value(g[2]) else { return g[0] }
                return g[1] + String(number) + g[3]
            }
        }
        // A bare, uppercase line is the common EPUB chapter-heading form.
        text = TextReplacement.replace(text, #"(?m)^([ \t]*)([IVXLCDM]{2,})([.)]?[ \t]*)$"#) { g in
            guard !["MIX","DIV","DI","MI","LI"].contains(g[2]), let number = value(g[2]) else { return g[0] }
            return g[1] + String(number) + g[3]
        }
        return text
    }
}
