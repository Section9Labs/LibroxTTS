// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog
import KokoroPronunciation

/// Optional, deterministic delivery refinements. Neither changes playback speed
/// nor loads a second model. Hosts persist these alongside the selected voice.
public struct NarrationDeliveryOptions: Codable, Equatable, Sendable {
    public var expressive: Bool
    public var blendedVoice: Bool
    public init(expressive: Bool = false, blendedVoice: Bool = false) {
        self.expressive = expressive; self.blendedVoice = blendedVoice
    }
    public var cacheIdentity: String { "delivery-options-1:expressive=\(expressive):blend=\(blendedVoice)" }
    /// Small reviewed audition pairings only. Unsupported voices retain their
    /// original reference; a new book or chapter never chooses a random blend.
    public func secondaryVoice(for voiceID: String) -> (id: String, weight: Float)? {
        guard blendedVoice else { return nil }
        let pairs: [String: (String, Float)] = ["ef_dora": ("em_santa", 0.15),
            "em_santa": ("em_alex", 0.25), "af_heart": ("af_bella", 0.20)]
        guard let pair = pairs[voiceID], let primary = Voice.named(voiceID),
              Voice.named(pair.0)?.language == primary.language else { return nil }
        return pair
    }
}

/// Source-local expression evidence. The optional renderer uses only exact
/// phoneme matches. No sentiment guessing or mood state crosses a speaker turn.
public enum NarrationExpressiveDelivery {
    public static let revision = "scoped-expression-1"
    public static func focus(text: String, sourceRange: NSRange, phonemes: String,
                             source: String, language: PronunciationLanguage,
                             options: PronunciationOptions) throws -> [NarrationFocus] {
        guard [.english, .spanish].contains(language), source.utf16.count <= 32_768,
              !phonemes.isEmpty else { return [] }
        let original = source as NSString
        // Closed quotes or a second dialogue dash establish an exact spoken
        // range and reporting-clause boundary. Never treat an entire paragraph
        // as angry simply because it contains an emotional word.
        let pattern = language == .english
            ? #"[“\"]([^”\"\r\n]+)[”\"]([^\r\n.!?]{0,160}[.!?]?)"#
            : #"(?:[«“\"]([^»”\"\r\n]+)[»”\"]|(?m:^[ \t]*—([^—\r\n]+)—))([^\r\n.!?]{0,160}[.!?]?)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let pronunciation = PronunciationEngine()
        var result: [NarrationFocus] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: original.length)) {
            let spoken = language == .english || match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let tag = match.range(at: language == .english ? 2 : 3)
            let evidence = NarrationMoodDetector.analyze(followingAttribution: original.substring(with: tag), languageCode: language.rawValue)
            guard evidence.mood != .neutral else { continue }
            let overlap = NSIntersectionRange(spoken, sourceRange)
            guard overlap.length > 0 else { continue }
            let local = NSRange(location: overlap.location - sourceRange.location, length: overlap.length)
            let unit = text as NSString
            let before = unit.substring(to: local.location)
            let through = unit.substring(to: NSMaxRange(local))
            // Prefix pronunciation can be context-sensitive. Admit a gesture
            // only when BOTH boundaries reproduce the actual renderer phones.
            let prefix = try pronunciation.phonemize(before, language: language, options: options).phonemes
            let end = try pronunciation.phonemize(through, language: language, options: options).phonemes
            guard phonemes.hasPrefix(end), end.hasPrefix(prefix) else { continue }
            let lo = prefix.unicodeScalars.count, hi = end.unicodeScalars.count
            guard hi > lo else { continue }
            let shift: Float = switch evidence.mood {
            case .angry: 0.65
            case .joyful: 0.8
            case .fearful: 0.35
            case .sad: -0.45
            case .relieved: -0.25
            case .neutral: 0
            }
            result.append(.init(phonemeRange: lo..<hi, semitones: shift,
                reason: "explicit-" + evidence.mood.rawValue))
            if result.count == 8 { break }
        }
        return result
    }
}
