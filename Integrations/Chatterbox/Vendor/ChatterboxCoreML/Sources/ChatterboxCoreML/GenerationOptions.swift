import Foundation

/// Sampling / decode-loop configuration.
///
/// The converter does not pin exact sampler parameters (the PyTorch reference
/// path uses its own sampler), so these defaults follow chatterbox-typical
/// values and should be validated against the PyTorch reference output.
/// Defaults mirror chatterbox `t3.inference_turbo`: temperature 0.8, top-k 1000,
/// top-p 0.95, repetition penalty 1.2 over the full generated history.
public struct GenerationOptions: Sendable {
    public var temperature: Float
    public var topK: Int
    public var topP: Float
    public var repetitionPenalty: Float
    /// Window (in most-recent generated tokens) over which the repetition penalty
    /// is applied. The reference uses the full history; the default is large
    /// enough to match that for normal lengths.
    public var repetitionWindow: Int
    public var minTokens: Int
    public var maxTokens: Int
    /// When true, ignore sampling and take the argmax each step. (Note: greedy
    /// decoding tends not to emit the stop token for TTS — prefer sampling.)
    public var greedy: Bool
    /// Optional fixed seed for reproducible sampling.
    public var seed: UInt64?

    // MARK: Multilingual-only

    /// Min-p nucleus floor (`MinPLogitsWarper`): keep tokens with
    /// `prob ≥ minP · maxProb`. `0` disables it (turbo uses top-k/top-p instead).
    /// The multilingual T3 loop uses min-p (no top-k); server default 0.05.
    public var minP: Float
    /// Classifier-free-guidance strength for the batch-2 multilingual decode:
    /// `logits = cond + cfgWeight·(cond − uncond)`. Ignored by the turbo (batch-1)
    /// path. Server default 0.5.
    public var cfgWeight: Float
    /// Emotion/exaggeration scalar feeding `emotion_adv_fc` in the cond block
    /// (multilingual only). Server default 0.5; Russian server uses 1.3.
    public var exaggeration: Float
    /// Language code for the multilingual tokenizer (`"ru"`, `"en"`, … or nil for
    /// no `[lang]` prefix). Ignored by the turbo path.
    public var language: String?

    // MARK: Playback pacing

    /// Silence (seconds) appended after each sentence's audio to space out
    /// delivery. `0` disables it (whole sentences pack into prefill-sized chunks
    /// as before). When > 0 the pipeline synthesizes one sentence per unit so the
    /// pause lands at every sentence boundary (`.!?` / newline).
    public var sentencePause: Double
    /// Silence (seconds) appended after each comma-delimited clause. `0` keeps
    /// commas inside their sentence (no extra split); > 0 splits at each comma so
    /// the clause voices its comma intonation, then pauses. Same one-unit-per-
    /// clause synthesis as `sentencePause`.
    public var commaPause: Double

    public init(
        temperature: Float = 0.8,
        topK: Int = 1000,
        topP: Float = 0.95,
        repetitionPenalty: Float = 1.2,
        repetitionWindow: Int = 100_000,
        minTokens: Int = 2,
        // Guard against non-terminating generation: ~40ms of audio per token, so
        // 1000 ≈ 40s. EOS normally fires well before this.
        maxTokens: Int = 1000,
        greedy: Bool = false,
        seed: UInt64? = nil,
        minP: Float = 0,
        cfgWeight: Float = MultilingualConstants.defaultCfgWeight,
        exaggeration: Float = 0.5,
        language: String? = nil,
        sentencePause: Double = 0,
        commaPause: Double = 0
    ) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionWindow = repetitionWindow
        self.minTokens = minTokens
        self.maxTokens = maxTokens
        self.greedy = greedy
        self.seed = seed
        self.minP = minP
        self.cfgWeight = cfgWeight
        self.exaggeration = exaggeration
        self.language = language
        self.sentencePause = sentencePause
        self.commaPause = commaPause
    }

    public static let `default` = GenerationOptions()

    /// Mirrors the multilingual server (`T3.inference` + Russian defaults): min-p
    /// nucleus (no top-k), temp 0.8, top-p 0.95, rep-penalty 1.2, cfg 0.5.
    /// Pass `language`/`exaggeration` per call (e.g. `"ru"`, 1.3).
    public static func multilingual(
        language: String?,
        exaggeration: Float = 0.5,
        cfgWeight: Float = MultilingualConstants.defaultCfgWeight,
        temperature: Float = 0.8,
        topP: Float = 0.95,
        minP: Float = 0.05,
        repetitionPenalty: Float = 1.2,
        maxTokens: Int = 1000,
        greedy: Bool = false,
        seed: UInt64? = nil
    ) -> GenerationOptions {
        GenerationOptions(
            temperature: temperature, topK: 0, topP: topP,
            repetitionPenalty: repetitionPenalty, minTokens: 2, maxTokens: maxTokens,
            greedy: greedy, seed: seed, minP: minP, cfgWeight: cfgWeight,
            exaggeration: exaggeration, language: language)
    }
}
