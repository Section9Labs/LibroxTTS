import Foundation

/// Splits text into chunks whose encoded length fits the T3 prefill window.
///
/// The padded prefill graph is fixed-length: `MAX - T_cond - 2` text tokens fit
/// (≈135 with the default voice). Longer text used to be silently truncated;
/// this packs whole sentences greedily into chunks under that budget, falling
/// back to word-splitting (then a hard token split) for a single oversize
/// sentence. Each chunk is a self-contained utterance the pipeline renders
/// independently; the caller concatenates / streams the resulting audio.
///
/// Token counting is delegated to an `encode` closure (the model passes the real
/// tokenizer; tests pass a fake), so the packing logic is unit-testable without
/// the model files.
struct TextChunker {
    /// Encodes text to tokens — same normalization the pipeline feeds the model.
    let encode: (String) -> [Int32]

    /// One synthesis unit: a chunk's text tokens plus the silence (seconds) to
    /// append after its rendered audio, so the caller can voice a pause between
    /// sentences / after commas (see `segments`).
    struct Segment: Equatable, Sendable {
        let tokens: [Int32]
        let trailingPause: Double
    }

    /// Returns the per-chunk token sequences, each with `count <= maxTokens`.
    /// Returns `[]` for empty/whitespace-only text.
    func chunk(_ text: String, maxTokens: Int) -> [[Int32]] {
        let budget = max(1, maxTokens)
        let segments = Self.sentences(text)
        guard !segments.isEmpty else { return [] }

        var chunks: [[Int32]] = []
        var group: [String] = []

        func flush() {
            guard !group.isEmpty else { return }
            chunks.append(encode(group.joined(separator: " ")))
            group = []
        }

        for segment in segments {
            if encode(segment).count > budget {
                // A single sentence overflows: emit what we have, then split it.
                flush()
                chunks.append(contentsOf: splitLong(segment, budget: budget))
                continue
            }
            if !group.isEmpty, encode((group + [segment]).joined(separator: " ")).count > budget {
                flush()
            }
            group.append(segment)
        }
        flush()
        return chunks
    }

    /// Like `chunk`, but for inserting pauses: splits at sentence terminators
    /// (`.!?` / newline) and commas so a configurable silence can follow each. A
    /// boundary only becomes a split point when its pause is > 0, so `commaPause
    /// == 0` keeps commas inside the sentence and both `== 0` yields one segment
    /// per sentence with no pauses. An oversize clause is still word-split to fit
    /// `maxTokens`; the pause rides only its final piece. The last segment never
    /// carries a trailing pause (no dead air at the very end). Empty/whitespace
    /// text → `[]`.
    ///
    /// Note this does **not** pack multiple sentences per chunk (unlike `chunk`) —
    /// each sentence/clause is its own unit so the pause lands at every boundary.
    func segments(_ text: String, maxTokens: Int, sentencePause: Double, commaPause: Double) -> [Segment] {
        let budget = max(1, maxTokens)

        // 1. Split into (clause, pause-after) pieces at active boundaries.
        var pieces: [(text: String, pause: Double)] = []
        var current = ""
        func push(_ pause: Double) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append((trimmed, pause)) }
            current = ""
        }
        for ch in text {
            if ch == "\n" { push(sentencePause); continue }
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                if sentencePause > 0 { push(sentencePause) }
            } else if ch == "," {
                if commaPause > 0 { push(commaPause) }
            }
        }
        push(0)                                   // trailing leftover, no pause
        guard !pieces.isEmpty else { return [] }

        // 2. Encode each piece; word-split an oversize clause (pause on last sub).
        var out: [Segment] = []
        for (clause, pause) in pieces {
            let toks = encode(clause)
            if toks.count <= budget {
                out.append(Segment(tokens: toks, trailingPause: pause))
            } else {
                let subs = splitLong(clause, budget: budget)
                for (i, sub) in subs.enumerated() {
                    out.append(Segment(tokens: sub, trailingPause: i == subs.count - 1 ? pause : 0))
                }
            }
        }
        // 3. No dead air after the final unit.
        if let last = out.indices.last {
            out[last] = Segment(tokens: out[last].tokens, trailingPause: 0)
        }
        return out
    }

    /// Pause-aware segments, or — when both pauses are `0` — the packed `chunk`
    /// output as zero-pause segments, so backends get one entry point and the
    /// no-pause path keeps the cheap sentence-packing behavior.
    func pausedSegments(_ text: String, maxTokens: Int, options: GenerationOptions) -> [Segment] {
        guard options.sentencePause > 0 || options.commaPause > 0 else {
            return chunk(text, maxTokens: maxTokens).map { Segment(tokens: $0, trailingPause: 0) }
        }
        return segments(text, maxTokens: maxTokens,
                        sentencePause: options.sentencePause, commaPause: options.commaPause)
    }

    /// Word-splits an oversize sentence; hard-splits a single oversize "word".
    private func splitLong(_ text: String, budget: Int) -> [[Int32]] {
        let words = text.split(separator: " ").map(String.init)
        var out: [[Int32]] = []
        var group: [String] = []

        func flush() {
            guard !group.isEmpty else { return }
            out.append(encode(group.joined(separator: " ")))
            group = []
        }

        for word in words {
            let wordTokens = encode(word)
            if wordTokens.count > budget {
                flush()
                var i = 0
                while i < wordTokens.count {
                    out.append(Array(wordTokens[i..<min(i + budget, wordTokens.count)]))
                    i += budget
                }
                continue
            }
            if !group.isEmpty, encode((group + [word]).joined(separator: " ")).count > budget {
                flush()
            }
            group.append(word)
        }
        flush()
        return out
    }

    /// Splits text into sentence-ish segments on `.!?` and newlines, keeping the
    /// terminal punctuation attached and trimming surrounding whitespace.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func push() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for ch in text {
            if ch == "\n" { push(); continue }
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" { push() }
        }
        push()
        return result
    }
}
