import Foundation
import Tokenizers
import Hub

/// Pluggable Russian stress source. An implementation takes plain (already
/// lowercased + NFKD-decomposed) Russian text and returns it with lexical stress
/// marked using the `+`-after-the-stressed-vowel convention (ruaccent's ASCII
/// form). `MTLTextTokenizer` then converts each `+` to a combining acute
/// (U+0301) in place. Manual marks in the input always survive, so an explicit
/// `+` / U+0301 the caller wrote wins over whatever the source would add.
///
/// `ManualRussianStress` is the identity (the caller supplies the marks);
/// `RuAccentStress` plugs the neural accentor (`iliasaz/ruaccent-coreml`) in here.
///
/// **Contract / ruaccent-coreml seam.** `stress` receives text that is
/// already **lowercased + NFKD-decomposed** (so `ё`→е+U+0308, `й`→и+U+0306) —
/// this matches the Python `MTLTokenizer.encode`, which calls `add_russian_stress`
/// *after* `preprocess_text`. The implementation may mark stress with either `+`
/// after the vowel (converted to U+0301 downstream) or U+0301 directly (passes
/// through). The ruaccent-coreml package exposes `stress(_:) -> String`; wrap it:
///
/// ```swift
/// import RuAccentCoreML  // SwiftPM dependency
/// struct RuAccentStress: RussianStressing {
///     let accentor: RuAccent
///     func stress(_ nfkdText: String) -> String { accentor.stress(nfkdText) }
/// }
/// // ChatterboxCoreMLModel.load(from: dir, russianStress: RuAccentStress(accentor: …))
/// ```
///
/// `DictionaryRussianStress` is the packed-dictionary / OOV fallback in the
/// meantime; manual marks in the input always win.
public protocol RussianStressing: Sendable {
    func stress(_ nfkdText: String) -> String
}

/// Identity stress source: relies entirely on caller-supplied `+` / U+0301 marks.
/// The default until the dictionary / neural sources land.
public struct ManualRussianStress: RussianStressing {
    public init() {}
    public func stress(_ nfkdText: String) -> String { nfkdText }
}

/// Exact-match dictionary stress source: maps a lowercased, NFKD-decomposed,
/// **unstressed** word to its `+`-marked form. Words already carrying a manual
/// mark (`+` or U+0301) are left untouched; OOV words pass through unchanged
/// (the OOV fallback the neural source replaces). The lookup is per-word
/// over the project's `[\p{L}]+`-style runs, punctuation/spacing preserved.
public struct DictionaryRussianStress: RussianStressing {
    /// key = unstressed lowercased NFKD word → value = `+`-marked form.
    private let table: [String: String]

    public init(table: [String: String]) { self.table = table }

    public func stress(_ nfkdText: String) -> String {
        var out = String()
        out.reserveCapacity(nfkdText.count)
        var word = String()
        func flush() {
            guard !word.isEmpty else { return }
            // Don't override a manually-marked word.
            if word.contains("+") || word.contains(MTLTextTokenizer.combiningAcute) {
                out += word
            } else {
                out += table[word] ?? word
            }
            word.removeAll(keepingCapacity: true)
        }
        for ch in nfkdText {
            // A "word" run is Cyrillic/Latin letters plus the combining marks NFKD
            // produced (Mn) and the manual `+` mark, so a marked word stays one run.
            if ch.isLetter || ch == "+" || ch.unicodeScalars.allSatisfy({ $0.properties.isDiacritic || ("\u{0300}"..."\u{036F}").contains($0) }) {
                word.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }
}

/// Multilingual grapheme-BPE tokenizer (`grapheme_mtl_merged_expanded_v1.json`,
/// 2454 vocab) loaded via swift-transformers, plus the multilingual preprocessing
/// chain from `chatterbox.models.tokenizers.MTLTokenizer` + `…TTS.generate`:
///
///   lowercase → NFKD → [ru stress] → `+`→U+0301 → "[<lang>]" prefix
///             → " "→"[SPACE]" → encode(addSpecialTokens:false)
///             → prepend SOT(255), append EOT(0)
///
/// NFKD is what performs the mandatory pure-Unicode Russian steps the plan calls
/// out (`ё`→е+U+0308, `й`→и+U+0306) — no bespoke code, just compatibility
/// decomposition. The neural Russian stresser plugs in via
/// `RussianStressing`; the default `ManualRussianStress` relies on caller marks.
public struct MTLTextTokenizer: Sendable {
    private let tokenizer: Tokenizer
    private let stresser: RussianStressing

    /// `[START]` = `T3Config.start_text_token`; `[STOP]` = `stop_text_token`.
    /// `…TTS.generate` pads these around the encoded ids (not via the tokenizer's
    /// own special-token machinery), so we add them by id here.
    public static let startTextToken: Int32 = 255
    public static let stopTextToken: Int32 = 0
    static let combiningAcute = "\u{0301}"
    private static let space = "[SPACE]"

    public init(modelFolder: URL, stresser: RussianStressing = ManualRussianStress()) async throws {
        do {
            self.tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder, strict: false)
        } catch {
            throw ChatterboxError.tokenizer("failed to load multilingual tokenizer from \(modelFolder.path): \(error)")
        }
        self.stresser = stresser
    }

    /// Memberwise init for tests (inject a preloaded `Tokenizer`).
    init(tokenizer: Tokenizer, stresser: RussianStressing = ManualRussianStress()) {
        self.tokenizer = tokenizer
        self.stresser = stresser
    }

    /// The MTL preprocessing chain (no special-token ids; see `encode`). Exposed
    /// for parity testing against the Python reference.
    func preprocess(_ text: String, language: String?) -> String {
        // Local V3 correction: the pinned en/es tokenizer config requests
        // NFKD,fullcase. Other languages retain upstream behavior pending parity.
        var t = (language == "en" || language == "es") ? text : text.lowercased()
        t = t.decomposedStringWithCompatibilityMapping  // NFKD
        if language == "ru" {
            t = stresser.stress(t)
            t = t.replacingOccurrences(of: "+", with: Self.combiningAcute)
        }
        if let language { t = "[\(language)]" + t }
        t = t.replacingOccurrences(of: " ", with: Self.space)
        return t
    }

    /// Full encode: preprocessed BPE ids wrapped with SOT/EOT, ready for the T3
    /// text-token input. `language` is a code like `"ru"`/`"en"` (nil = no lang
    /// prefix, matching `text_to_tokens(language_id=None)`).
    public func encode(_ text: String, language: String?) -> [Int32] {
        let pre = preprocess(text, language: language)
        let ids = tokenizer.encode(text: pre, addSpecialTokens: false).map(Int32.init)
        return [Self.startTextToken] + ids + [Self.stopTextToken]
    }

    /// BPE ids without the SOT/EOT wrapper (the raw `text_to_tokens` output).
    func encodeBare(_ text: String, language: String?) -> [Int32] {
        tokenizer.encode(text: preprocess(text, language: language), addSpecialTokens: false).map(Int32.init)
    }
}
