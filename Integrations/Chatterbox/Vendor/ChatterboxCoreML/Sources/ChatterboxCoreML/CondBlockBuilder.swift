import Foundation

/// Host-side reproduction of `T3.prepare_conditioning` + `T3CondEnc.forward` for
/// the multilingual model: builds the 34-row conditioning prefix
/// `[spkr(1); perceiver(prompt→32); emotion(1)]` of shape `(34, 1024)`.
///
/// Decision #6: this is computed host-side (it depends only on the reference
/// voice + exaggeration, not the text) so the prefill CoreML graph stays
/// structurally like turbo's. Validated against the real PyTorch output via
/// the `mtl-cond` fixtures (`CondBlockTests`).
///
///   spkr     = spkr_enc(speaker_emb)                          (Linear 256→1024)
///   perceiver= Perceiver(speech_emb(prompt)+speech_pos_emb)   (→ 32 rows)
///   emotion  = emotion_adv_fc(exaggeration)                   (Linear 1→1024, no bias)
struct CondBlockBuilder: Sendable {
    static let dim = Perceiver.dim          // 1024
    static let rows = 1 + Perceiver.queryLen + 1   // 34

    private let perceiver: Perceiver
    private let spkr: SpeakerProjection     // 256 → 1024
    private let emotionWeight: [Float]      // emotion_adv_fc.weight (1024,1) → (1024,)

    init(dir: URL) throws {
        perceiver = try Perceiver(dir: dir)
        spkr = try SpeakerProjection(
            weightURL: dir.appendingPathComponent("spkr_enc_weight.npy"),
            biasURL: dir.appendingPathComponent("spkr_enc_bias.npy"))
        let (w, shape) = try NPYFloat32.read(url: dir.appendingPathComponent("emotion_adv_fc_weight.npy"))
        // (1024, 1) row-major → 1024 contiguous; emotion row = w[:,0] · exaggeration.
        guard w.count == Self.dim, shape.first == Self.dim else {
            throw ChatterboxError.npy("emotion_adv_fc_weight shape \(shape) (count \(w.count)) != (\(Self.dim),1)")
        }
        emotionWeight = w
    }

    init(perceiver: Perceiver, spkr: SpeakerProjection, emotionWeight: [Float]) {
        self.perceiver = perceiver
        self.spkr = spkr
        self.emotionWeight = emotionWeight
    }

    /// Assembles the flat `(34, 1024)` cond block. `condPromptSpeechEmb` is the
    /// flat `(promptLen, 1024)` speech-token embedding of the prompt **with the
    /// learned speech position embedding already added** (the Llama-path input the
    /// Perceiver consumes).
    func build(speakerEmb: [Float], condPromptSpeechEmb: [Float], promptLen: Int, exaggeration: Float) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(Self.rows * Self.dim)
        out.append(contentsOf: spkr.project(speakerEmb))                       // spkr (1 row)
        out.append(contentsOf: perceiver.forward(condPromptSpeechEmb, n: promptLen))  // perceiver (32 rows)
        out.append(contentsOf: emotionWeight.map { $0 * exaggeration })       // emotion (1 row)
        return out
    }
}
