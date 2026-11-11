// Port of Kyutai pocket_tts/models/text_chunking.py at 28770c06 (MIT).
import Foundation

public enum PocketTTSTextUtils {
    private static let closers = "\"'”’)]»"
    private static let titles: Set<String> = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Rev.", "vs.", "e.g.", "i.e."]
    /// Internal clauses retain punctuation and case so teacher-forced audio and
    /// its text prefix describe the same continuing sentence.
    public static func prepareTextPrompt(_ text: String, config: PocketTTSModelConfig,
                                         preserveSentenceBoundaries: Bool = false) throws -> (String, Int) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !config.replaceCharacters.isEmpty {
            value = value.map { config.replaceCharacters[String($0)] ?? String($0) }.joined()
            value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            value = value.replacingOccurrences(of: #"([.!?…])\s*[,;:]"#, with: "$1", options: .regularExpression)
        }
        guard !value.isEmpty else { throw PocketTTSError.emptyText }
        value = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "  ", with: " ")
        if config.removeSemicolons && !preserveSentenceBoundaries { value = value.replacingOccurrences(of: ";", with: ",") }
        let count = value.split(whereSeparator: \.isWhitespace).count
        if !preserveSentenceBoundaries, let first = value.first, !first.isUppercase { value = first.uppercased() + value.dropFirst() }
        var core = value
        while let last = core.last, (closers + " ").contains(last) { core.removeLast() }
        if !preserveSentenceBoundaries, let last = core.last, !".!?…".contains(last) {
            if ",;:-–—".contains(last) {
                let suffix = value.dropFirst(core.count).trimmingCharacters(in: .whitespaces)
                while let last = core.last, ",;:-–— ".contains(last) { core.removeLast() }
                value = core + "." + suffix
            } else { value += "." }
        }
        if config.padShortInputs && count < 5 { value = String(repeating: " ", count: 8) + value }
        return (value, count <= 4 ? 3 : 1)
    }

    public static func splitIntoBestSentences(_ tokenizer: PocketTTSSentencePieceTokenizer, _ text: String,
                                              maxTokens: Int, config: PocketTTSModelConfig) throws -> [String] {
        guard (1...100).contains(maxTokens), text.unicodeScalars.count <= 16_384 else { throw PocketTTSError.textTooLong }
        let prepared = try prepareTextPrompt(text, config: config).0.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = tokenizer.encode(prepared)
        func boundaries(_ tokens: [Int], marks: Set<Int>) -> [Int] {
            var indices = [0], wasBoundary = false
            for (index, token) in tokens.enumerated() {
                if marks.contains(token) { wasBoundary = true; continue }
                if wasBoundary {
                    let after = tokenizer.decode(Array(tokens[(index - 1)...index]))
                    let next = after.dropFirst().first
                    let start = max(0, index - 6)
                    let words = tokenizer.decode(Array(tokens[start..<index])).split(whereSeparator: \.isWhitespace)
                    let isTitle = words.last.map { titles.contains(String($0)) } == true && (words.count > 1 || start == 0)
                    if !(next?.isLetter == true || next?.isNumber == true || isTitle) {
                        let punctuation = tokenizer.decode([tokens[index - 1]])
                        var boundary = index
                        for end in (index + 1)...min(tokens.count, index + 8) {
                            let window = tokenizer.decode(Array(tokens[(index - 1)..<end]))
                            let tail = window.dropFirst(punctuation.count)
                            if tail.isEmpty || tail.contains(where: { !(closers + "�").contains($0) }) { break }
                            if !tail.contains("�") { boundary = end }
                        }
                        if boundary < tokens.count { indices.append(boundary) }
                    }
                }
                wasBoundary = false
            }
            indices.append(tokens.count)
            return indices
        }
        func segments(_ tokens: [Int], marks: Set<Int>) -> [(Int, String)] {
            let indices = boundaries(tokens, marks: marks)
            return zip(indices, indices.dropFirst()).map { ($1 - $0, tokenizer.decode(Array(tokens[$0..<$1]))) }
        }
        let sentenceMarks = Set(tokenizer.encode(".!...?").dropFirst())
        let clauseMarks = Set(tokenizer.encode(",;:").dropFirst())
        var refined: [(Int, String)] = []
        for segment in segments(tokens, marks: sentenceMarks) {
            if segment.0 <= maxTokens { refined.append(segment); continue }
            let subs = segments(tokenizer.encode(segment.1.trimmingCharacters(in: .whitespaces)), marks: clauseMarks)
            refined += subs.count > 1 ? subs : [segment]
        }
        var glued: [(Int, String)] = []
        for segment in refined {
            if let last = glued.last, last.1.range(of: #"\d[.,]\d+\W*$"#, options: .regularExpression) != nil {
                glued[glued.count - 1] = (last.0 + segment.0, last.1.trimmingCharacters(in: .whitespaces) + " " + segment.1.trimmingCharacters(in: .whitespaces))
            } else { glued.append(segment) }
        }
        var chunks: [String] = [], current = "", count = 0
        for (size, sentence) in glued {
            if !current.isEmpty && count + size > maxTokens {
                chunks.append(current.trimmingCharacters(in: .whitespaces)); current = ""; count = 0
            }
            current += (current.isEmpty ? "" : " ") + sentence; count += size
        }
        if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespaces)) }
        // Upstream warns for oversized unbreakable clauses. Fail explicitly instead
        // of silently skipping words, and let the host revise/split the input.
        guard chunks.allSatisfy({ tokenizer.encode($0).count <= 256 }) else { throw PocketTTSError.textTooLong }
        return chunks
    }
}
