import Foundation
import RUAccentCoreML

/// Bridges `ruaccent-coreml`'s `RUAccent` to chatterbox's `RussianStressing`.
/// The two protocols are different types (chatterbox's is sync /
/// non-throwing / `Sendable`; RUAccent's is throwing / has `notation` / class-bound),
/// so this adapter is mandatory. Lives inside the `ChatterboxCoreML` module so the
/// unqualified `RussianStressing` binds to chatterbox's protocol.
///
/// `MTLTextTokenizer` hands us text that is already **lowercased + NFKD** (so
/// `ё`→`е`+U+0308, `й`→`и`+U+0306), and afterwards replaces `"+"`→U+0301 **in
/// place**. Two correctness traps, both verified by the ruaccent team against the
/// real models:
///
///  1. NOTATION — ask for `.combiningAcute` (U+0301 *after* the vowel). The other
///     notation (`.plusBeforeVowel`, e.g. `"м+ой"`) would, after chatterbox's
///     in-place `"+"`→U+0301 replace, land the acute on the *preceding consonant*
///     (`"м́ой"`). With `.combiningAcute` RUAccent already emits the acute, so
///     chatterbox's replace is a harmless no-op.
///
///  2. NFKD round-trip — RUAccent's `normalize` accepts only *composed* Cyrillic
///     and STRIPS bare combining marks (U+0308/U+0306/U+0301). Feeding raw NFKD
///     corrupts `ё`/`й` words (`"мой"`→`"мои́"`, `"самолёт"`→`"самолё́т"`). So
///     NFC-compose before stressing and re-NFKD the result, matching what
///     chatterbox's grapheme tokenizer was trained on.
///
/// On any failure we return the input unchanged so TTS degrades to caller-supplied
/// marks. `@unchecked Sendable` is sound: `RUAccent` is a `final class` wrapping
/// load-once, immutable CoreML models; `stress(_:notation:)` is a read-only
/// inference path with no mutable shared state.
public struct RuAccentStress: RussianStressing, @unchecked Sendable {
    public let accentor: RUAccent

    public init(accentor: RUAccent) { self.accentor = accentor }

    public func stress(_ nfkdText: String) -> String {
        let composed = nfkdText.precomposedStringWithCanonicalMapping        // NFC for RUAccent
        guard let stressed = try? accentor.stress(composed, notation: .combiningAcute) else {
            return nfkdText                                                  // fail-open
        }
        return stressed.decomposedStringWithCompatibilityMapping            // back to NFKD
    }
}

extension RuAccentStress {
    /// Builds the multilingual Russian stress source for `ChatterboxCoreMLModel.load`.
    /// Prefers a local ruaccent model dir (`coreml/`, `dictpack/`, `nn/` — the
    /// converter's `_work` layout) if given; otherwise downloads
    /// `iliasaz/ruaccent-coreml` using the **same** HF token + HF_HOME chatterbox
    /// uses for its own model (they write
    /// sibling dirs under one cache). On any failure (offline / download error /
    /// load error) returns `ManualRussianStress` so TTS still runs on
    /// caller-supplied `+`/U+0301 marks.
    public static func makeOrFallback(
        localDirectory: URL? = nil,
        downloadHFHome: URL? = nil,
        hfToken: String? = nil
    ) async -> RussianStressing {
        do {
            let accentor: RUAccent
            if let localDirectory {
                accentor = try RUAccent(modelDirectory: localDirectory)
                Log.load.notice("[ruaccent] loaded from local dir \(localDirectory.path, privacy: .public)")
            } else {
                accentor = try await RUAccent(hfHome: downloadHFHome, hfToken: hfToken)
                Log.load.notice("[ruaccent] downloaded + loaded \(RUAccentCoreML.ModelRepository.defaultRepoId, privacy: .public)")
            }
            return RuAccentStress(accentor: accentor)
        } catch {
            Log.load.error("[ruaccent] unavailable — falling back to manual stress marks: \(error.localizedDescription, privacy: .public)")
            return ManualRussianStress()
        }
    }
}
