import Foundation
import CryptoKit
import LibroxChatterbox
import KokoroNarration

// Same frozen Mac policy fingerprint, shared for source/options admission even
// when a complete encoded artifact is reused without loading the model.
extension ChatterboxChapterRenderOptions {
    package func canonicalSynthesisIdentity(rendererProfile: String) throws -> String {
        struct Options: Encodable {
            let revision, language, direction, grouping, expression, profile, planner, cadence, scope: String
            let seed: UInt64
            let maxTokens: Int
            let decoderExecution, bufferPolicy, waveform, watermark: String
            let acousticSteps: Int
            let acousticGuidance: Float
            let vocoderSeed: UInt64
        }
        let value = Options(revision: "mac-standard-chapter-synthesis-1", language: language,
            direction: direction == .neutral ? "neutral" : "storyteller", grouping: grouping.cacheRevision,
            expression: expressionSHA256, profile: rendererProfile, planner: ChatterboxBookDirector.revision,
            cadence: ConversationCadence.revision, scope: ChatterboxNarrationScope.chapterV1.rawValue, seed: seed,
            maxTokens: 350, decoderExecution: "eager-1", bufferPolicy: "trim-between-units-1",
            waveform: "deterministic-gather-2", watermark: "disabled-1", acousticSteps: 10, acousticGuidance: 0.7, vocoderSeed: 42)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
