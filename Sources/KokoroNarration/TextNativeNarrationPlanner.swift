import Foundation
import NaturalLanguage
import KokoroPronunciation
import LibroxCTNative

/// Source context is retained up to the actual normalized-token budget. Source
/// ranges always address the book, even when spoken dictionary readings expand.
public enum TextNativeNarrationPlanner {
    public static let revision = "ct-context-tokens-2:" + SpokenTextLexicon.revision
    public enum PlanningError: Error { case invalidVoice, unbreakableText }
    public static func plan(_ text: String, voiceID: String,
                            lexicon: SpokenTextLexicon = .init()) throws -> [BookNarrationUnit] {
        guard text.unicodeScalars.count <= PronunciationEngine.maximumInputScalars else {
            throw PronunciationError.inputTooLong(limit: PronunciationEngine.maximumInputScalars)
        }
        guard let voice = NarrationModel.plus.nativeVoices.first(where: { $0.id == voiceID }) else {
            throw PlanningError.invalidVoice
        }
        let source = text as NSString
        func spoken(_ range: NSRange) -> String { lexicon.text(source.substring(with: range), language: voice.language) }
        func fits(_ range: NSRange) -> Bool {
            guard let normalized = try? CTTokenizer.normalize(spoken(range), language: voice.language,
                                                              completeSentence: false) else { return false }
            return normalized.unicodeScalars.count <= 500
        }
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: voice.language))
        var sentences: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(NSRange(range, in: text)); return true
        }
        if sentences.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences = [NSRange(location: 0, length: source.length)]
        }
        var ranges: [NSRange] = []
        for sentence in sentences {
            var start = sentence.location
            while start < NSMaxRange(sentence) {
                try Task.checkCancellation()
                var end = NSMaxRange(sentence)
                if !fits(NSRange(location: start, length: end - start)) {
                    // Grow by grapheme clusters; never split a surrogate pair,
                    // combining sequence, or hang while scanning CJK text.
                    var cursor = start, lastBreak = start
                    while cursor < end {
                        let cluster = source.rangeOfComposedCharacterSequence(at: cursor)
                        let next = NSMaxRange(cluster)
                        guard fits(NSRange(location: start, length: next - start)) else { break }
                        cursor = next
                        if source.substring(with: cluster).contains(where: { $0.isWhitespace || ",;:，、；：".contains($0) }) {
                            lastBreak = cursor
                        }
                    }
                    end = lastBreak > start ? lastBreak : cursor
                    guard end > start else { throw PlanningError.unbreakableText }
                }
                let part = NSRange(location: start, length: end - start)
                if let prior = ranges.last {
                    let gap = source.substring(with: NSRange(location: NSMaxRange(prior), length: start - NSMaxRange(prior)))
                    let combined = NSRange(location: prior.location, length: end - prior.location)
                    if !gap.contains("\n"), fits(combined) { ranges[ranges.count - 1] = combined }
                    else { ranges.append(part) }
                } else { ranges.append(part) }
                start = end
            }
        }
        return ranges.enumerated().map { index, range in
            let original = source.substring(with: range)
            let ending = original.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}」』"))
            let next = index + 1 < ranges.count ? ranges[index + 1].location : source.length
            let gap = source.substring(with: NSRange(location: NSMaxRange(range), length: next - NSMaxRange(range)))
            let terminal = ending.last.map { ".!?…。！？؟।॥".contains($0) } == true
            let boundary: NarrationBoundary = gap.contains("\n") ? .paragraph : terminal ? .sentence : .continuation
            var unit = BookNarrationUnit(sourceText: original, sourceRange: range, narratorID: voiceID, boundaryAfter: boundary)
            unit.spokenText = spoken(range)
            unit.prosody = NarrationProsody.analyze(text: original, languageCode: voice.language)
            return unit
        }
    }
}
