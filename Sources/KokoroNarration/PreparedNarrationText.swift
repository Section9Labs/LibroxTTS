import Foundation
import KokoroPronunciation
import LibroxCTNative

/// Per-plan preparation of stable clauses and the still-changing final clause.
/// All offsets refer to the original UTF-16 source. A clause boundary is admitted
/// only where the orthographic rules cannot read across it. Unsupported inputs
/// retain the original full-prefix evaluator.
final class PreparedNarrationText {
    private struct Key: Hashable { let text: String; let context: String }
    private struct Part { let spoken: String; let normalized: String }
    private let source: NSString
    private let language: String
    private let plainLexicon = SpokenTextLexicon()
    private let lexicon: SpokenTextLexicon
    private let origin: Int
    private let stops: [Int]
    private var parts: [Key: Part] = [:]

    init?(_ text: String, language: String, lexicon: SpokenTextLexicon, origin: Int) {
        guard ["en", "es", "fr", "pt", "it"].contains(language),
              !text.contains(where: \.isNewline),
              !lexicon.entries.contains(where: {
                  $0.language == language && ($0.written.contains(where: { ";!?,".contains($0) || $0.isNewline })
                      || $0.spoken.contains(where: \.isNewline))
              }) else { return nil }
        source = text as NSString
        self.language = language; self.lexicon = lexicon; self.origin = origin
        var stops: [Int] = [], offset = 0
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            offset += String(character).utf16.count
            if ";!?".contains(character) || (character == "," && index + 1 < characters.count && characters[index + 1] == " ") {
                stops.append(offset)
            }
        }
        guard !stops.isEmpty else { return nil }
        self.stops = stops
    }

    func fits(_ range: NSRange, model: NarrationModel, maximum: Int, allowEmptyPrefix: Bool) -> Bool? {
        let start = range.location - origin, end = NSMaxRange(range) - origin
        guard start >= 0, end <= source.length, end >= start else { return nil }
        var cursor = start, spokenCount = 0, normalized = ""
        // A comma is stable only after its following space has arrived. Before
        // then it may still belong to a numeric token at the end of this prefix.
        let endpoints = stops.filter { $0 > start && $0 < end } + [end]
        for stop in endpoints {
            let text = source.substring(with: NSRange(location: cursor, length: stop - cursor))
            let initial = cursor == start
            let context = initial ? "" : String(UnicodeScalar(source.character(at: cursor - 1))!)
            let key = Key(text: text, context: context)
            let part: Part
            if let cached = parts[key] { part = cached }
            else {
                // Preserve line-start Roman rules for the first clause only.
                // The fixed nonnumeric sentinel supplies the preceding punctuation
                // context for later clauses and cannot match a custom reading.
                let spoken: String
                if initial { spoken = lexicon.text(text, language: language) }
                else {
                    // Apply readings before the sentinel: user dictionaries must
                    // never see or replace synthetic context.
                    let read = lexicon.applyingReadings(to: text, language: language)
                    let plain = plainLexicon.text("x" + context + read, language: language)
                    guard plain.hasPrefix("x" + context) else { return nil }
                    spoken = String(plain.dropFirst(2))
                }
                // Retain leading/trailing spaces, unlike standalone normalize.
                // The final x prevents trimming; tags and sentinels are private.
                guard spoken.unicodeScalars.count <= 4090,
                      let wrapped = try? CTTokenizer.normalize("x;" + spoken + "x", language: language, completeSentence: false) else { return nil }
                let body = String(wrapped.dropFirst(language.count + 4).dropLast(language.count + 4))
                part = Part(spoken: spoken, normalized: body)
                // Bound memory independently of the number of prefixes scanned.
                if parts.count < 4096 { parts[key] = part }
            }
            spokenCount += part.spoken.unicodeScalars.count
            if normalized.last == " ", part.normalized.first == " " { normalized += part.normalized.dropFirst() }
            else { normalized += part.normalized }
            cursor = stop
        }
        if model == .pocket { return spokenCount <= maximum }
        guard spokenCount <= 4096 else { return false }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.unicodeScalars.contains(where: { CharacterSet.letters.union(.decimalDigits).contains($0) }) else { return allowEmptyPrefix }
        return normalized.unicodeScalars.count + 2 * language.count + 5 <= 500
    }
}
