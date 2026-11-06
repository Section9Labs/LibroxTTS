// Adapted from Supertone helper, Copyright (c) 2025 Supertone Inc.
// MIT license: see Resources/helper-LICENSE.
import Foundation

/// Port of the frozen helper's NFKD Unicode indexer. No phoneme frontend is used.
public struct CTTokenizer: Sendable {
    private let indexer: [Int64]
    public init(directory: URL) throws {
        indexer = try JSONDecoder().decode([Int64].self, from: Data(contentsOf:
            directory.appendingPathComponent("config/unicode_indexer.json")))
        guard indexer.count == 65_536 else { throw CTError.invalidAssets("unicode_indexer") }
    }
    public func encode(_ text: String, language: String) throws -> [Int64] {
        let normalized = try Self.normalize(text, language: language)
        guard normalized.unicodeScalars.count <= 512 else { throw CTError.passageTooLong }
        return try normalized.unicodeScalars.map {
            // The pinned Python helper casts to uint16; don't alias unsupported
            // non-BMP characters to unrelated letters in mobile text.
            guard $0.value < 65_536 else { throw CTError.invalidTensor("unsupported Unicode scalar") }
            return indexer[Int($0.value)]
        }
    }
    public static func normalize(_ source: String, language: String) throws -> String {
        guard ["en", "es"].contains(language) else { throw CTError.unsupportedLanguage }
        guard source.unicodeScalars.count <= 4096 else { throw CTError.passageTooLong }
        var text = source.decomposedStringWithCompatibilityMapping
        text = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            let v = scalar.value
            return ![(0x1f600...0x1f64f), (0x1f300...0x1f5ff), (0x1f680...0x1f6ff),
                     (0x1f700...0x1f77f), (0x1f780...0x1f7ff), (0x1f800...0x1f8ff),
                     (0x1f900...0x1f9ff), (0x1fa00...0x1fa6f), (0x1fa70...0x1faff),
                     (0x2600...0x26ff), (0x2700...0x27bf), (0x1f1e6...0x1f1ff)].contains { $0.contains(Int(v)) }
        }))
        for (from, to) in [("–", "-"), ("‑", "-"), ("—", "-"), ("_", " "),
            ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"), ("´", "'"), ("`", "'"),
            ("[", " "), ("]", " "), ("|", " "), ("/", " "), ("#", " "), ("→", " "), ("←", " ")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        for symbol in ["♥", "☆", "♡", "©", "\\"] { text = text.replacingOccurrences(of: symbol, with: "") }
        for (from, to) in [("@", " at "), ("e.g.,", "for example, "), ("i.e.,", "that is, ")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        for punctuation in [",", ".", "!", "?", ";", ":", "'"] {
            text = text.replacingOccurrences(of: " " + punctuation, with: punctuation)
        }
        for quote in ["\"", "'", "`"] {
            while text.contains(quote + quote) { text = text.replacingOccurrences(of: quote + quote, with: quote) }
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.union(.decimalDigits).contains($0) }) else {
            throw CTError.emptyText
        }
        if let last = text.last, !".!?;:,'\")]}…。」』】〉》›»".contains(last) { text += "." }
        return "<\(language)>" + text + "</\(language)>"
    }
}
