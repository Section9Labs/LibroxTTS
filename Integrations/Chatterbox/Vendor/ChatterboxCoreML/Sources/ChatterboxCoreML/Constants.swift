import Foundation

/// Architecture constants for Chatterbox Turbo, mirroring upstream's T3 / S3Gen
/// hyperparameters. The HuggingFace artifact bundle does
/// not ship a `config.json`, so these are fixed here.
public enum Constants {
    public static let speechVocabSize = 6563
    public static let speechStopToken = 6562
    // Chatterbox T3Config.start_speech_token. The prefill is seeded with this BOS
    // token (content tokens are 0..6560; 6561 = start, 6562 = stop).
    public static let speechStartToken = 6561
    /// Generated speech tokens are clamped to this inclusive range before being
    /// handed to the conditional decoder (matches `scripts/play_sample.py`).
    public static let speechTokenMaxValid = 6560

    public static let gpt2Hidden = 1024
    public static let gpt2Heads = 16
    public static let gpt2Layers = 24
    public static let gpt2HeadDim = gpt2Hidden / gpt2Heads // 64

    public static let speakerEmbDim = 256   // T3 prefill speaker_emb
    public static let camppEmbDim = 192     // conditional decoder speaker_embeddings
    public static let melBins = 80
    public static let promptFeatFrames = 500 // gen.prompt_feat is (500, 80)

    public static let sampleRate: Double = 24000

    /// The S3Encoder graph's hard `speech_tokens` bound: its input dimension is
    /// `RangeDim(1, 1024)` with **default shape 1024**. Nothing may be fed past
    /// this; in practice nothing is fed *at* it either — see `maxVocoderTokens`.
    public static let encoderTokenLimit = 1024

    /// Maximum `speech_tokens` length actually fed to the S3Encoder. The synth
    /// feeds it `prompt ++ generated`, so that sum must stay within this bound;
    /// `SynthRunner` windows the generated tokens when it doesn't.
    ///
    /// **Four below `encoderTokenLimit` on purpose.** At exactly 1024 — the
    /// RangeDim *default* shape, i.e. the one the accelerators actually specialize
    /// for — the exported encoder fails at predict time on both accelerator CUs
    /// while cpuOnly stays correct, so this is an accelerator-lowering bug at the
    /// default shape, not a graph error (measured 2026-07-26, M-series host + A-series
    /// device, same `out/S3Encoder.mlpackage`):
    ///
    /// | T     | cpuOnly | cpuAndNeuralEngine        | cpuAndGPU                    |
    /// |-------|---------|---------------------------|------------------------------|
    /// | ≤1020 | ok      | ok (271 ms @ 1020)        | ok                           |
    /// | 1024  | ok      | `E5RT … BNNS Op (11)`     | MPSGraph `Type is unranked.` |
    ///
    /// On iOS the ANE failure surfaces as `No memory object bound to port` raised as
    /// an **Objective-C** `NSGenericException` out of `MLModel.prediction(from:)` —
    /// uncatchable from Swift, so it terminates the app rather than failing the
    /// utterance. It was reachable in the foreground whenever a chunk over-generated
    /// past one window: `SynthRunner.tokenWindows` makes every non-final window
    /// exactly `windowBudget` long, so a multi-window synth fed `prompt ++ window`
    /// == exactly the cap on its first pass — i.e. *every* foreground multi-window
    /// utterance crashed. (Background pins the CFM to the ANE, which caps windows at
    /// `cfmPadTarget/2 − prompt` ≈ 262 and never came near it.)
    ///
    /// 1020 is a multiple of 4, so `SynthRunner.synthesizeWindow`'s pad-up-to-a-
    /// multiple-of-4 can never push a capped window back onto 1024.
    public static let maxVocoderTokens = 1020

    /// Conservative upper bound on generated **speech** tokens per **text** token,
    /// used to size text chunks so a chunk's generation fits one S3Encoder window
    /// (`maxVocoderTokens − prompt`). Measured ≈6.6 on narration prose; 8 leaves
    /// headroom. Overshoots are still safe — `SynthRunner` windows them — this
    /// just keeps the common path to a single, seam-free vocoder pass.
    public static let maxSpeechTokensPerTextToken = 8
}

/// Architecture constants for **nano** (GPT2_small backbone). Nano differs from
/// turbo (`Constants`, GPT2_medium) ONLY in the T3 backbone's depth and width —
/// speech vocab, text vocab, window, `speech_cond_prompt_len`, and the whole S3Gen
/// synth are bit-identical, so nano reads everything else from `Constants`.
///
/// The runtime reconstructs NO geometry from these: `hidden` is read off the graph
/// (`inputs_embeds`) and the KV feature width off the state buffer (nano 9216 vs
/// turbo 24576), which is what lets one code path drive both GPT-2 depths. `hidden`
/// is the variant discriminator (`ChatterboxCoreMLModel.load` matches it against
/// `speech_emb.npy`); `layers` only describes the shipped graph. `EndToEndTests`
/// pins both against the real `T3LM` (KV row == layers · hidden).
public enum NanoConstants {
    public static let hidden = 768   // 12 heads × 64 — same head_dim as turbo's 1024/16
    public static let layers = 12
}

/// Architecture constants for the **multilingual** T3 (LLaMA_520M backbone),
/// mirroring upstream's `T3Config.multilingual()`. Distinct from the turbo
/// `Constants` (GPT-2-medium) so both pipelines can coexist; the runtime selects
/// by which `T3LM.mlpackage` is loaded. Speech side (start/stop/max-valid) is
/// shared with turbo; the text side, depth, and head geometry differ.
public enum MultilingualConstants {
    public static let hidden = 1024
    public static let heads = 16
    public static let headDim = hidden / heads          // 64
    public static let layers = 30

    public static let speechVocabSize = 8194            // speech_head output width
    public static let speechStartToken = 6561
    public static let speechStopToken = 6562
    public static let speechTokenMaxValid = 6560

    public static let textVocabSize = 2454
    /// `T3Config.start_text_token` / `stop_text_token` ([START] / [STOP]); padded
    /// around the encoded text by `MTLTextTokenizer.encode`.
    public static let startTextToken: Int32 = 255
    public static let stopTextToken: Int32 = 0

    public static let speakerEmbDim = 256               // cond_enc.spkr_enc input
    public static let perceiverQueryLen = 32
    /// Conditioning prefix rows: spkr(1) + perceiver(32) + emotion(1).
    public static let condRows = 1 + perceiverQueryLen + 1   // 34

    public static let batch = 2                         // CFG lanes (row0 cond, row1 uncond)
    public static let window = 512                      // prefill window (W)
    public static let maxSeq = 1536                     // shared KV-cache width (MAX_SEQ)

    /// Fixed CFG strength baked into the multilingual flow is separate; this is the
    /// T3 token-CFG default (`cond + cfg·(cond−uncond)`), server default 0.5.
    public static let defaultCfgWeight: Float = 0.5
}
