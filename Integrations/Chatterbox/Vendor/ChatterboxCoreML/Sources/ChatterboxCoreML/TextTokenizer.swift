import Foundation
import Tokenizers
import Hub

/// GPT-2 BPE tokenizer wrapper over swift-transformers, loaded from the
/// `tokenizer.json` / `tokenizer_config.json` shipped in the model directory.
/// Also recognizes the 19 emotion tags from `added_tokens.json`
/// (e.g. `[happy]`, `[whispering]`).
struct TextTokenizer: Sendable {
    private let tokenizer: Tokenizer

    init(modelFolder: URL) async throws {
        do {
            self.tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder, strict: false)
        } catch {
            throw ChatterboxError.tokenizer("failed to load tokenizer from \(modelFolder.path): \(error)")
        }
    }

    /// Encodes text into the `text_tokens` int32 sequence consumed by the CoreML
    /// prefill. Special tokens are not auto-added; the T3 prefill builds its own
    /// conditioning prefix. (If reference output indicates a start/stop text
    /// token is required, flip `addSpecialTokens`.)
    func encode(_ text: String) -> [Int32] {
        tokenizer.encode(text: Self.puncNorm(text), addSpecialTokens: false).map(Int32.init)
    }

    /// Port of chatterbox `tts_turbo.punc_norm`: capitalize, collapse spaces,
    /// normalize uncommon punctuation, and ensure terminal punctuation.
    static func puncNorm(_ input: String) -> String {
        if input.isEmpty { return "You need to add some text for me to talk." }
        var text = input
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        text = text.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        let replacements: [(String, String)] = [
            ("…", ", "), (":", ","), ("—", "-"), ("–", "-"), (" ,", ","),
            ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
        ]
        for (old, new) in replacements { text = text.replacingOccurrences(of: old, with: new) }
        text = String(text.reversed().drop(while: { $0 == " " }).reversed())
        let enders: Set<Character> = [".", "!", "?", "-", ","]
        if let last = text.last, !enders.contains(last) { text += "." }
        return text
    }
}
