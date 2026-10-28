import Foundation
import CoreML

/// Abstracts the T3 front end (tokenize + prefill/decode) so
/// `ChatterboxCoreMLModel` can drive either the **turbo** (GPT-2, batch-1) or the
/// **multilingual** (LLaMA_520M, batch-2 CFG) pipeline behind one orchestration
/// (chunking, streaming, synth). The synth stack (`SynthRunner`) is already
/// variant-agnostic (it auto-detects the CFM), so only the T3 front end forks.
protocol T3Backend: Sendable {
    var selectedComputeUnits: MLComputeUnits { get }
    /// Prefill window width (`inputs_embeds` seq dim).
    var maxLen: Int { get }

    /// Splits `text` into per-chunk text-token arrays that each fit the prefill
    /// (and single-vocoder-pass) budget for `conds`, ready for `generate`.
    func chunk(_ text: String, conds: Conditionals, options: GenerationOptions) -> [[Int32]]

    /// Pause-aware chunking: same per-chunk budget as `chunk`, but splits at
    /// sentence/comma boundaries and tags each unit with the trailing silence
    /// (`options.sentencePause` / `.commaPause`) to append after its audio. With
    /// both pauses `0` this is `chunk` with zero-pause segments (packed, cheap).
    func segments(_ text: String, conds: Conditionals, options: GenerationOptions) -> [TextChunker.Segment]

    /// Generates the speech tokens for one chunk (prefill + decode loop).
    func generate(textTokens: [Int32], conds: Conditionals, options: GenerationOptions) throws -> T3Result
}

/// One chunk's decode result + per-stage timings (variant-agnostic).
struct T3Result: Sendable {
    let tokens: [Int]
    let prefillLength: Int
    let prefillTime: TimeInterval
    let decodeTime: TimeInterval
    var hostAssemblyTime: TimeInterval = 0
    var conditioningCacheHit: Bool? = nil
    var decodeStepTimings: DecodeStepTimings? = nil
}

// MARK: - Turbo (GPT-2, batch-1)

/// Turbo front end: `TextTokenizer` (GPT-2 BPE) + the batch-1 `T3LMRunner`.
/// Behavior is identical to the pre-refactor inline path.
struct TurboBackend: T3Backend {
    var selectedComputeUnits: MLComputeUnits { runner.selectedComputeUnits }
    let tokenizer: TextTokenizer
    let runner: T3LMRunner

    var maxLen: Int { runner.maxLen }

    private func chunkerAndBudget(conds: Conditionals) -> (TextChunker, Int) {
        let budget = ChatterboxCoreMLModel.textBudget(
            maxLen: runner.maxLen,
            condPromptSpeechTokenCount: conds.condPromptSpeechTokens.count,
            synthPromptTokenCount: conds.promptTokens.count)
        return (TextChunker(encode: { tokenizer.encode($0) }), budget)
    }

    func chunk(_ text: String, conds: Conditionals, options: GenerationOptions) -> [[Int32]] {
        let (chunker, budget) = chunkerAndBudget(conds: conds)
        return chunker.chunk(text, maxTokens: budget)
    }

    func segments(_ text: String, conds: Conditionals, options: GenerationOptions) -> [TextChunker.Segment] {
        let (chunker, budget) = chunkerAndBudget(conds: conds)
        return chunker.pausedSegments(text, maxTokens: budget, options: options)
    }

    func generate(textTokens: [Int32], conds: Conditionals, options: GenerationOptions) throws -> T3Result {
        let out = try runner.generate(textTokens: textTokens, conds: conds, options: options)
        return T3Result(tokens: out.tokens, prefillLength: out.prefillLength,
                        prefillTime: out.prefillTime, decodeTime: out.decodeTime)
    }
}

// MARK: - Multilingual (LLaMA_520M, batch-2 CFG)

/// Multilingual front end: `MTLTextTokenizer` (grapheme BPE + Russian Unicode +
/// the `RussianStressing` seam) + the batch-2 CFG `MTLT3LMRunner`. `options`
/// carries `language` / `exaggeration` / `cfgWeight`; the cond prefix is the
/// fixed 34-row spkr+perceiver+emotion block, so the prefill text budget is
/// `window − 34 − 2` regardless of the prompt length.
struct MultilingualBackend: T3Backend {
    var selectedComputeUnits: MLComputeUnits { runner.selectedComputeUnits }
    let tokenizer: MTLTextTokenizer
    let runner: MTLT3LMRunner

    var maxLen: Int { runner.maxLen }

    private func chunkerAndBudget(conds: Conditionals, options: GenerationOptions) -> (TextChunker, Int) {
        let prefillBudget = max(1, runner.maxLen - MultilingualConstants.condRows - 2)
        let vocoderWindow = Constants.maxVocoderTokens - conds.promptTokens.count
        let vocoderBudget = max(1, vocoderWindow / Constants.maxSpeechTokensPerTextToken)
        let budget = min(prefillBudget, vocoderBudget)
        // The encode (incl. `[lang]` + SOT/EOT) is what the prefill consumes, so the
        // chunker measures and emits exactly those token arrays.
        let lang = options.language
        return (TextChunker(encode: { tokenizer.encode($0, language: lang) }), budget)
    }

    func chunk(_ text: String, conds: Conditionals, options: GenerationOptions) -> [[Int32]] {
        let (chunker, budget) = chunkerAndBudget(conds: conds, options: options)
        return chunker.chunk(text, maxTokens: budget)
    }

    func segments(_ text: String, conds: Conditionals, options: GenerationOptions) -> [TextChunker.Segment] {
        let (chunker, budget) = chunkerAndBudget(conds: conds, options: options)
        return chunker.pausedSegments(text, maxTokens: budget, options: options)
    }

    func generate(textTokens: [Int32], conds: Conditionals, options: GenerationOptions) throws -> T3Result {
        let out = try runner.generate(textTokens: textTokens, conds: conds, options: options)
        return T3Result(tokens: out.tokens, prefillLength: out.prefillLength,
                        prefillTime: out.prefillTime, decodeTime: out.decodeTime,
                        hostAssemblyTime: out.hostAssemblyTime,
                        conditioningCacheHit: out.conditioningCacheHit, decodeStepTimings: out.decodeStepTimings)
    }
}
