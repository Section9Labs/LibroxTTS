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
                pieces += try splitLongSentence(sentence, maximum: options.maximumTokens,
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
                    let short = min(tokenCount(try prepare(piece)), tokenCount(try prepare(current)))
                        <= options.shortSentenceTokens
                    let linked = beginsContinuation(piece, language: language)
                    // Never break a sentence merely to meet a soft target. A short
                    // response/follow-on may stay with its setup up to the hard cap.
                    let keep = count <= options.maximumTokens &&
                        (count <= target || short || linked || boundary != .sentence)
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

    private static func splitLongSentence(_ text: String, maximum: Int,
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
