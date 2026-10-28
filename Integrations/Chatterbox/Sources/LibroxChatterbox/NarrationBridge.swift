import Foundation
import KokoroNarration

/// Source offsets and stable casting belong to the existing narration library.
/// No Kokoro phonemes or style vectors are sent to Chatterbox.
public struct ChatterboxSourceContext: Sendable {
    public let range: NSRange
    public let originalText: String
    public let voiceID: String
    public let speakerID: String?
    public let performance: NarrationPerformance
}

public enum ChatterboxNarrationBridge {
    /// Every selected voice needs an explicit compatible conditioning file.
    /// This prevents silently playing all existing cast IDs in one default voice.
    public static func prepare(_ unit: BookNarrationUnit, source: String,
                               followingAttribution: String = "", languageCode: String,
                               conditioningFiles: [String: URL],
                               override: NarrationPerformanceOverride? = nil,
                               maxTokens: Int = 350, seed: UInt64? = nil) throws -> ChatterboxRequest {
        let original = source as NSString
        guard unit.range.location != NSNotFound, unit.range.location >= 0,
              unit.range.length >= 0, unit.range.location <= original.length,
              unit.range.length <= original.length - unit.range.location else {
            throw ChatterboxNarrationError.invalidSourceRange
        }
        guard let conditioning = conditioningFiles[unit.voiceID] else {
            throw ChatterboxNarrationError.missingVoiceConditioning(unit.voiceID)
        }
        guard original.substring(with: unit.range) == unit.text else {
            throw ChatterboxNarrationError.sourceTextMismatch
        }
        let performance = NarrationPerformance.analyze(unit: unit,
            followingAttribution: followingAttribution, languageCode: languageCode, override: override)
        let suggestion = performance.chatterboxSuggestion
        let context = ChatterboxSourceContext(range: unit.range,
            originalText: original.substring(with: unit.range), voiceID: unit.voiceID,
            speakerID: unit.speakerID, performance: performance)
        return try ChatterboxRequest(text: unit.text, language: languageCode,
            conditioningFile: conditioning, exaggeration: suggestion.exaggeration,
            guidance: suggestion.cfgWeight, maxTokens: maxTokens, seed: seed, sourceContext: context)
    }
}

/// Optional completed-unit seam timing using the existing library's rules.
/// Do not call once per arbitrary model chunk. The caller buffers one bounded
/// unit, then calls this before playback and resets on seek/book/generation change.
public struct ChatterboxConversationSession: Sendable {
    private var cadence = ConversationCadence()
    public init() {}
    public mutating func reset() { cadence.reset() }
    @discardableResult
    public mutating func completeUnit(_ samples: inout [Float], context: DialogueTimingContext,
                                      sampleRate: Int = 24_000) throws -> ConversationCadenceResult {
        guard sampleRate == ChatterboxAudioChunk.expectedSampleRate else {
            throw ChatterboxNarrationError.invalidSampleRate(sampleRate)
        }
        return cadence.apply(to: &samples, context: context, sampleRate: sampleRate)
    }
}
