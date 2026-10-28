import CoreML
import Foundation
import Safetensors

/// Voice conditioning loaded from a `*-conds.safetensors` file.
///
/// Keys (confirmed from the `default-conds.safetensors` header):
///   t3.speaker_emb                 f32 [256]
///   t3.cond_prompt_speech_tokens   i32 [375]
///   gen.embedding                  f32 [192]
///   gen.prompt_token               i32 [250]
///   gen.prompt_token_len           i32 [1]
///   gen.prompt_feat                f32 [500, 80]
struct Conditionals: Sendable {
    /// T3 prefill `speaker_emb` input — raw 256-dim speaker embedding.
    let speakerEmb: [Float]
    /// T3 prefill `cond_speech_tokens` input.
    let condPromptSpeechTokens: [Int32]
    /// Conditional decoder `speaker_embeddings` — CAMPPlus 192-dim, NOT yet normalized.
    let genEmbedding: [Float]
    /// Conditional decoder prompt token prefix (already trimmed to prompt_token_len).
    let promptTokens: [Int32]
    /// Conditional decoder `speaker_features`, flattened (500 * 80), C-order.
    let promptFeat: [Float]

    /// Memberwise initializer (used by tests to build synthetic conditioning).
    init(
        speakerEmb: [Float],
        condPromptSpeechTokens: [Int32],
        genEmbedding: [Float],
        promptTokens: [Int32],
        promptFeat: [Float]
    ) {
        self.speakerEmb = speakerEmb
        self.condPromptSpeechTokens = condPromptSpeechTokens
        self.genEmbedding = genEmbedding
        self.promptTokens = promptTokens
        self.promptFeat = promptFeat
    }

    init(contentsOf url: URL) throws {
        let st = try Safetensors.read(at: url)

        func floats(_ key: String) throws -> [Float] {
            do { return try st.array(forKey: key) as [Float] }
            catch { throw ChatterboxError.invalidModelOutput("conds key '\(key)': \(error)") }
        }
        func int32s(_ key: String) throws -> [Int32] {
            do { return try st.array(forKey: key) as [Int32] }
            catch { throw ChatterboxError.invalidModelOutput("conds key '\(key)': \(error)") }
        }

        self.speakerEmb = try floats("t3.speaker_emb")
        self.condPromptSpeechTokens = try int32s("t3.cond_prompt_speech_tokens")
        self.genEmbedding = try floats("gen.embedding")
        self.promptFeat = try floats("gen.prompt_feat")

        let rawPromptTokens = try int32s("gen.prompt_token")
        // Trim to the valid length if present; otherwise use the full row.
        if let len = (try? int32s("gen.prompt_token_len"))?.first.map({ Int($0) }),
           len >= 0, len <= rawPromptTokens.count {
            self.promptTokens = Array(rawPromptTokens.prefix(len))
        } else {
            self.promptTokens = rawPromptTokens
        }
    }

    /// L2-normalized CAMPPlus embedding for the conditional decoder.
    var normalizedSpeakerEmbedding: [Float] {
        let norm = max(sqrt(genEmbedding.reduce(0) { $0 + $1 * $1 }), 1e-12)
        return genEmbedding.map { $0 / norm }
    }

    /// Writes the flat-key `*-conds.safetensors` the loader reads — byte-schema
    /// identical to upstream's `Conditionals` with batch dims removed. Used by `VoiceCloner`
    /// to persist an on-device-cloned voice. `prompt_feat` is stored (frames, 80).
    func write(to url: URL) throws {
        let frames = promptFeat.count / Constants.melBins
        let tensors: [String: any SafetensorsEncodable] = [
            "t3.speaker_emb": try MLMultiArray.float32(speakerEmb, shape: [speakerEmb.count]),
            "t3.cond_prompt_speech_tokens":
                try MLMultiArray.int32(condPromptSpeechTokens, shape: [condPromptSpeechTokens.count]),
            "gen.embedding": try MLMultiArray.float32(genEmbedding, shape: [genEmbedding.count]),
            "gen.prompt_token": try MLMultiArray.int32(promptTokens, shape: [promptTokens.count]),
            "gen.prompt_token_len": try MLMultiArray.int32([Int32(promptTokens.count)], shape: [1]),
            "gen.prompt_feat": try MLMultiArray.float32(promptFeat, shape: [frames, Constants.melBins]),
        ]
        try Safetensors.write(tensors, to: url)
    }
}
