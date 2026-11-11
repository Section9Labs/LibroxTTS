import Foundation
import KokoroPronunciation

/// Per-plan scalar prefix sums for a proven plain-text domain. Original UTF-16
/// offsets remain the keys; unsupported text and non-grapheme endpoints abstain.
struct PlainNarrationBudget {
    private let source: [UInt16]
    private let nfc: [Int]
    private let nfkd: [Int]
    private let letters: [Int]
    private let boundaries: [Bool]
    private let tagScalars: Int

    init?(_ text: String, language: String, lexicon: SpokenTextLexicon) {
        guard lexicon.entries.isEmpty, let code = PronunciationLanguage(rawValue: language),
              TextNormalizer.permitsPlainPrefixCounting(text, language: code) else { return nil }
        source = Array(text.utf16)
        var nfc = [Int](repeating: 0, count: source.count + 1), nfkd = nfc, letters = nfc
        var boundaries = [Bool](repeating: false, count: source.count + 1)
        var offset = 0, canonicalCount = 0, compatibilityCount = 0, letterCount = 0
        boundaries[0] = true
        for character in text {
            let original = String(character)
            let canonical = original.precomposedStringWithCanonicalMapping
            let compatibility = canonical.decomposedStringWithCompatibilityMapping
            canonicalCount += canonical.unicodeScalars.count
            compatibilityCount += compatibility.unicodeScalars.count
            letterCount += compatibility.unicodeScalars.contains(where: CharacterSet.letters.contains) ? 1 : 0
            offset += original.utf16.count
            nfc[offset] = canonicalCount; nfkd[offset] = compatibilityCount; letters[offset] = letterCount
            boundaries[offset] = true
        }
        self.nfc = nfc; self.nfkd = nfkd; self.letters = letters; self.boundaries = boundaries
        tagScalars = 2 * language.unicodeScalars.count + 5
    }

    func fits(_ range: NSRange, model: NarrationModel, maximum: Int, allowEmptyPrefix: Bool) -> Bool? {
        let start = range.location, end = NSMaxRange(range)
        guard start >= 0, end <= source.count, boundaries[start], boundaries[end] else { return nil }
        let spokenCount = nfc[end] - nfc[start]
        if model == .pocket { return spokenCount <= maximum }
        guard spokenCount <= 4096 else { return false }
        guard letters[end] > letters[start] else { return allowEmptyPrefix }
        var count = nfkd[end] - nfkd[start]
        if start < end, source[start] == 32 { count -= 1 }
        if end > start + 1, source[end - 1] == 32 { count -= 1 }
        return count + tagScalars <= 500
    }
}
