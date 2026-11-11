import Foundation
import NaturalLanguage
import KokoroCatalog

/// Inspectable synthesis decisions. Text is the prepared reading, not a book range.
public struct PocketTTSTextChunk: Sendable, Equatable {
    public enum Boundary: String, Sendable { case sentence, clause, word, paragraph }
    public let text: String
    public let tokenCount: Int
    public let boundaryAfter: Boundary
    public let startsNewPassage: Bool
}

/// Structural heuristics, not emotion or speaker inference. The book planner
/// supplies one speaker turn at a time. Paragraphs always reset continuation.
public enum PocketTTSPassageChunker {
    public static func plan(_ text: String, language: String, role: PocketTTSPassageRole,
                     options: PocketTTSChunkingOptions,
                     prepare: (String) throws -> String,
                     tokenCount: (String) -> Int) throws -> [PocketTTSTextChunk] {
        try options.validate()
        guard text.unicodeScalars.count <= 16_384 else { throw PocketTTSError.textTooLong }
        let target = role == .dialogue ? options.dialogueTargetTokens : options.narrationTargetTokens
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(NLLanguage(rawValue: language))
        var paragraphs: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byParagraphs) { value, _, _, _ in
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { paragraphs.append(value) }
        }
        var result: [PocketTTSTextChunk] = []
        for paragraph in paragraphs {
            try Task.checkCancellation()
            let prepared = try prepare(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            if options.grouping == .keepTogether {
                let count = tokenCount(try prepare(prepared))
                guard count <= options.maximumTokens else { throw PocketTTSError.textTooLong }
                result.append(.init(text: prepared, tokenCount: count, boundaryAfter: .paragraph,
                                    startsNewPassage: true))
                continue
            }
            tokenizer.string = prepared
            var sentences: [String] = []
            tokenizer.enumerateTokens(in: prepared.startIndex..<prepared.endIndex) { range, _ in
                sentences.append(String(prepared[range]).trimmingCharacters(in: .whitespacesAndNewlines))
                return true
            }
            if sentences.isEmpty { sentences = [prepared] }
            var pieces: [(String, PocketTTSTextChunk.Boundary)] = []
            for sentence in sentences {
                pieces += try splitLongSentence(sentence, target: target, maximum: options.maximumTokens,
                                                prepare: prepare, tokenCount: tokenCount)
            }
            var current = "", boundary = PocketTTSTextChunk.Boundary.sentence
            var first = true
            func emit(_ ending: PocketTTSTextChunk.Boundary) throws {
                guard !current.isEmpty else { return }
                let spoken = try prepare(current).trimmingCharacters(in: .whitespacesAndNewlines)
                let count = tokenCount(spoken)
                guard count <= options.maximumTokens else { throw PocketTTSError.textTooLong }
                result.append(.init(text: current, tokenCount: count, boundaryAfter: ending, startsNewPassage: first))
                first = false; current = ""
            }
            for (piece, ending) in pieces {
                if !current.isEmpty {
                    let joined = current + " " + piece
                    let count = tokenCount(try prepare(joined))
                    let currentCount = tokenCount(try prepare(current))
                    let short = min(tokenCount(try prepare(piece)), currentCount)
                        <= options.shortSentenceTokens
                    // A soft target is not a reason to isolate a tiny clause.
                    // Choose the nearer natural boundary, allowing a bounded
                    // overshoot only when joining improves the target distance.
                    let nearerClauseBoundary = boundary == .clause &&
                        abs(count - target) < abs(currentCount - target)
                    let linked = beginsContinuation(piece, language: language)
                    // Keep small complete thoughts together, but do not undo an
                    // internal clause boundary selected for a long sentence.
                    let keep = count <= options.maximumTokens &&
                        (count <= target || nearerClauseBoundary ||
                         (boundary == .sentence && ending == .sentence && (short || linked)))
                    if !keep { try emit(boundary) }
                }
                current += (current.isEmpty ? "" : " ") + piece
                boundary = ending
            }
            try emit(.paragraph)
        }
        guard !result.isEmpty else { throw PocketTTSError.emptyText }
        return result
    }

    private static func beginsContinuation(_ text: String, language: String) -> Bool {
        // Deliberately small, language-specific cues; no inferred emotional labels.
        let cues: [String: Set<String>] = [
            "en": ["and", "but", "because", "so", "yet", "then", "instead", "however"],
            "es": ["y", "pero", "porque", "entonces", "aunque"],
            "fr": ["et", "mais", "car", "donc", "pourtant", "alors"],
            "de": ["und", "aber", "denn", "deshalb", "doch", "dann"],
            "pt": ["e", "mas", "porque", "então", "porém"],
            "it": ["e", "ma", "perché", "quindi", "però", "allora"],
            "nl": ["en", "maar", "want", "dus", "toch", "dan"]
        ]
        let first = text.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init)
        return first.map { cues[language]?.contains($0) == true } ?? false
    }

    private static func splitLongSentence(_ text: String, target: Int, maximum: Int,
                                          prepare: (String) throws -> String,
                                          tokenCount: (String) -> Int) throws -> [(String, PocketTTSTextChunk.Boundary)] {
        if tokenCount(try prepare(text)) <= target { return [(text, .sentence)] }
        // Only existing clause punctuation justifies a soft-target split. Keep
        // unpunctuated clauses intact up to the hard cap; never invent a stop.
        var clauses: [String] = []
        var start = text.startIndex
        for index in text.indices where text[index].isWhitespace {
            let prefix = text[start..<index].trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.last.map({ ",;:—–".contains($0) }) == true {
                clauses.append(prefix)
                start = text.index(after: index)
            }
        }
        let tail = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { clauses.append(tail) }
        if clauses.count > 1 {
            var pieces: [(String, PocketTTSTextChunk.Boundary)] = []
            for (index, clause) in clauses.enumerated() {
                var split = try splitAtHardLimit(clause, maximum: maximum, prepare: prepare, tokenCount: tokenCount)
                if index < clauses.count - 1, let last = split.popLast() {
                    split.append((last.0, .clause))
                }
                pieces += split
            }
            return pieces
        }
        return try splitAtHardLimit(text, maximum: maximum, prepare: prepare, tokenCount: tokenCount)
    }

    private static func splitAtHardLimit(_ text: String, maximum: Int,
                                         prepare: (String) throws -> String,
                                         tokenCount: (String) -> Int) throws -> [(String, PocketTTSTextChunk.Boundary)] {
        if tokenCount(try prepare(text)) <= maximum { return [(text, .sentence)] }
        var remaining = text[...], output: [(String, PocketTTSTextChunk.Boundary)] = []
        while !remaining.isEmpty {
            try Task.checkCancellation()
            if tokenCount(try prepare(String(remaining))) <= maximum {
                output.append((String(remaining), .sentence)); break
            }
            var wordBreak: String.Index?, clauseBreak: String.Index?
            // Whole-word boundaries preserve composed characters, decimal values
            // and names. A single oversized word fails explicitly, never truncates.
            for index in remaining.indices where remaining[index].isWhitespace {
                let prefix = String(remaining[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prefix.isEmpty else { continue }
                if tokenCount(try prepare(prefix)) > maximum { break }
                wordBreak = index
                if prefix.last.map({ ",;:—–".contains($0) }) == true { clauseBreak = index }
            }
            guard let end = clauseBreak ?? wordBreak else { throw PocketTTSError.textTooLong }
            output.append((String(remaining[..<end]), clauseBreak == nil ? .word : .clause))
            remaining = remaining[end...].drop(while: \.isWhitespace)
        }
        return output
    }
}
