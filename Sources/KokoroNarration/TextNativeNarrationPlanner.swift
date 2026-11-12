import KokoroCatalog
import Foundation
import NaturalLanguage
import KokoroPronunciation
import LibroxCTNative

/// Source context is retained up to the actual normalized-token budget. Source
/// ranges always address the book, even when spoken dictionary readings expand.
public enum TextNativeNarrationPlanner {
    public static let revision = "ct-context-tokens-3:" + SpokenTextLexicon.revision
    public enum PlanningError: Error { case invalidVoice, unbreakableText }
    public static func plan(_ text: String, voiceID: String,
                            lexicon: SpokenTextLexicon = .init(), model: NarrationModel = .plus,
                            pocketChunking: PocketTTSChunkingOptions = .init()) throws -> [BookNarrationUnit] {
        guard text.unicodeScalars.count <= PronunciationEngine.maximumInputScalars else {
            throw PronunciationError.inputTooLong(limit: PronunciationEngine.maximumInputScalars)
        }
        guard let voice = model.nativeVoices.first(where: { $0.id == voiceID }) else {
            throw PlanningError.invalidVoice
        }
        if model == .pocket { try pocketChunking.validate() }
        let source = text as NSString
        var plainBudget: PlainNarrationBudget?
        func spoken(_ range: NSRange) -> String { lexicon.text(source.substring(with: range), language: voice.language) }
        func fits(_ range: NSRange, allowEmptyPrefix: Bool = false) -> Bool {
            if let result = plainBudget?.fits(range, model: model, maximum: pocketChunking.maximumUnitScalars,
                                              allowEmptyPrefix: allowEmptyPrefix) { return result }
            if model == .pocket {
                // The source planner preserves speaker/paragraph boundaries; the
                // renderer applies sentence-aware budgets with the real tokenizer.
                return spoken(range).unicodeScalars.count <= pocketChunking.maximumUnitScalars
            }
            do {
                let normalized = try CTTokenizer.normalize(spoken(range), language: voice.language,
                                                            completeSentence: false)
                return normalized.unicodeScalars.count <= 500
            } catch CTError.emptyText {
                // A leading quote or indentation is not a complete utterance,
                // but it must not prevent a long sentence from being scanned.
                return allowEmptyPrefix
            } catch { return false }
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(NLLanguage(rawValue: voice.language))
        var sentences: [NSRange] = []
        // EPUBs commonly contain indented blank lines. NLTokenizer can emit
        // those as tokens, or include paragraph breaks in a sentence range.
        // Tokenize each paragraph so neither becomes a synthesis request.
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byParagraphs) { paragraph, range, _, _ in
            guard let paragraph, paragraph.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            let offset = NSRange(range, in: text).location
            tokenizer.string = paragraph
            var local: [NSRange] = []
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { sentence, _ in
                if paragraph[sentence].contains(where: { $0.isLetter || $0.isNumber }) {
                    let token = NSRange(sentence, in: paragraph)
                    local.append(NSRange(location: offset + token.location, length: token.length))
                }
                return true
            }
            sentences += local.isEmpty ? [NSRange(range, in: text)] : local
        }
        var ranges: [NSRange] = []
        for sentence in sentences {
            // Contextual material elsewhere in a book must not disqualify a
            // safe sentence. Cross-sentence budget checks still use full rules.
            plainBudget = nil
            var checkedPlainBudget = false
            var start = sentence.location
            while start < NSMaxRange(sentence) {
                try Task.checkCancellation()
                var end = NSMaxRange(sentence)
                if !fits(NSRange(location: start, length: end - start)) {
                    if model == .pocket, pocketChunking.grouping == .keepTogether {
                        throw PlanningError.unbreakableText
                    }
                    if !checkedPlainBudget {
                        plainBudget = PlainNarrationBudget(source.substring(with: sentence), language: voice.language,
                            lexicon: lexicon, origin: sentence.location)
                        checkedPlainBudget = true
                    }
                    // Grow by grapheme clusters; never split a surrogate pair,
                    // combining sequence, or hang while scanning CJK text.
                    var cursor = start, lastBreak = start
                    while cursor < end {
                        try Task.checkCancellation()
                        let cluster = source.rangeOfComposedCharacterSequence(at: cursor)
                        let next = NSMaxRange(cluster)
                        guard fits(NSRange(location: start, length: next - start), allowEmptyPrefix: true) else { break }
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
                    if !gap.contains(where: { $0.isNewline }), fits(combined) { ranges[ranges.count - 1] = combined }
                    else {
                        if model == .pocket, pocketChunking.grouping == .keepTogether,
                           !gap.contains(where: { $0.isNewline }) { throw PlanningError.unbreakableText }
                        ranges.append(part)
                    }
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
            let boundary: NarrationBoundary = gap.contains(where: { $0.isNewline }) ? .paragraph : terminal ? .sentence : .continuation
            var unit = BookNarrationUnit(sourceText: original, sourceRange: range, narratorID: voiceID, boundaryAfter: boundary)
            unit.spokenText = spoken(range)
            if model == .pocket { unit.pocketChunking = pocketChunking }
            unit.prosody = NarrationProsody.analyze(text: original, languageCode: voice.language)
            return unit
        }
    }
}
