import Foundation
import NaturalLanguage
import KokoroPronunciation

/// Keeps multi-sentence source context up to the native model's bounded input.
/// The host retains original UTF-16 ranges for seeking; it never supplies phonemes.
public enum TextNativeNarrationPlanner {
    public static let revision = "ct-context-300-v1"
    public enum PlanningError: Error { case invalidVoice, unbreakableText }
    public static func plan(_ text: String, voiceID: String) throws -> [BookNarrationUnit] {
        guard NarrationModel.plus.nativeVoices.contains(where: { $0.id == voiceID }) else { throw PlanningError.invalidVoice }
        let source = text as NSString
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(NSRange(range, in: text)); return true
        }
        if ranges.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ranges = [NSRange(location: 0, length: source.length)]
        }
        var result: [NSRange] = []
        for range in ranges {
            try Task.checkCancellation()
            var remainder = range
            while remainder.length > 0 {
                var end = min(NSMaxRange(remainder), remainder.location + 280)
                if end < NSMaxRange(remainder) {
                    while end > remainder.location, !(UnicodeScalar(source.character(at: end - 1)).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false) { end -= 1 }
                    guard end > remainder.location else { throw PlanningError.unbreakableText }
                }
                let part = NSRange(location: remainder.location, length: end - remainder.location)
                if let prior = result.last, end - prior.location <= 280,
                   !source.substring(with: NSRange(location: NSMaxRange(prior), length: part.location - NSMaxRange(prior))).contains("\n") {
                    result[result.count - 1] = NSRange(location: prior.location, length: end - prior.location)
                } else { result.append(part) }
                remainder = NSRange(location: end, length: NSMaxRange(remainder) - end)
            }
        }
        return result.map { range in
            let passage = source.substring(with: range)
            let ending = passage.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}"))
            let boundary: NarrationBoundary = ending.last.map { ".!?…。！？".contains($0) } == true ? .sentence : .continuation
            return BookNarrationUnit(sourceText: passage, sourceRange: range, narratorID: voiceID, boundaryAfter: boundary)
        }
    }
}
