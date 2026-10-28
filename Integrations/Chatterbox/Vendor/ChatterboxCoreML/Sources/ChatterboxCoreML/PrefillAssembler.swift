import Foundation

/// Host-side assembly for the padded T3 prefill contract
/// (`docs/T3LM-multifunction-contract.md`).
///
/// The ANE-friendly `T3Prefill` graph is a clean, fixed-length transformer: the
/// token-embedding lookups and speaker projection moved out of the model and
/// onto the host. This type builds the three padded inputs the graph expects
/// (`inputs_embeds`, `position_ids`, `key_padding_mask`) and computes how to
/// slice the real KV cache out of the padded output. It is deliberately free of
/// CoreML so the assembly logic can be unit-tested in isolation.
struct PrefillAssembler: Sendable {
    let speechEmb: SpeechEmbedding
    let textEmb: EmbeddingTable
    let spkrProjection: SpeakerProjection
    /// Static sequence length of the graph (the converter's `--prefill-max`).
    let maxLen: Int
    /// Hidden width of the T3 graph (turbo 1024, nano 768). Deliberately has **no
    /// default**: a caller silently inheriting turbo's width against a nano graph
    /// yields garbage audio, not an error.
    let hidden: Int

    init(
        speechEmb: SpeechEmbedding,
        textEmb: EmbeddingTable,
        spkrProjection: SpeakerProjection,
        maxLen: Int,
        hidden: Int
    ) {
        self.speechEmb = speechEmb
        self.textEmb = textEmb
        self.spkrProjection = spkrProjection
        self.maxLen = maxLen
        self.hidden = hidden
    }

    /// The host-assembled, left-padded prefill inputs.
    struct Assembled: Sendable {
        var inputsEmbeds: [Float]   // flat (maxLen * hidden), C-order, pads at front
        var positionIds: [Int32]    // (maxLen)
        var keyPaddingMask: [Int32] // (maxLen)
        var nPad: Int               // number of left-pad rows = maxLen - realLength
        var realLength: Int         // T_real = 1 + T_cond + T_text + 1
    }

    /// Builds the padded inputs in the contract's exact order:
    /// `[spkr_e] ++ cond_e ++ text_e ++ [speech_e]`, left-padded to `maxLen`.
    ///
    /// Text tokens are truncated (never the conditioning) if the real sequence
    /// would exceed `maxLen`.
    func assemble(textTokens: [Int32], conds: Conditionals) -> Assembled {
        let condTokens = conds.condPromptSpeechTokens
        let tCond = condTokens.count

        // Truncation policy: conditioning is the voice and is never trimmed.
        let textBudget = max(0, maxLen - tCond - 2)
        let usedText = textTokens.count > textBudget
            ? Array(textTokens.prefix(textBudget))
            : textTokens
        let tText = usedText.count

        let realLength = 1 + tCond + tText + 1
        let nPad = maxLen - realLength

        // Build the real (unpadded) rows, then left-pad into the full buffer.
        var real: [Float] = []
        real.reserveCapacity(realLength * hidden)
        real.append(contentsOf: spkrProjection.project(conds.speakerEmb)) // spkr_e (1 row)
        for t in condTokens { speechEmb.appendRow(Int(t), to: &real) }    // cond_e
        for t in usedText { textEmb.appendRow(Int(t), to: &real) }        // text_e
        speechEmb.appendRow(Constants.speechStartToken, to: &real)        // speech_e (1 row)

        var inputsEmbeds = [Float](repeating: 0, count: maxLen * hidden)
        let realStart = nPad * hidden
        for i in 0..<real.count { inputsEmbeds[realStart + i] = real[i] }

        var positionIds = [Int32](repeating: 0, count: maxLen)
        var keyPaddingMask = [Int32](repeating: 0, count: maxLen)
        for j in 0..<realLength {
            positionIds[nPad + j] = Int32(j)
            keyPaddingMask[nPad + j] = 1
        }

        return Assembled(
            inputsEmbeds: inputsEmbeds,
            positionIds: positionIds,
            keyPaddingMask: keyPaddingMask,
            nPad: nPad,
            realLength: realLength
        )
    }

    /// Front-aligned assembly for the **stateful** multifunction prefill
    /// (`T3LM` "prefill" function). Identical content/order to `assemble`, but
    /// real rows occupy the **front** `[0..realLength-1]` (pad at the tail), so
    /// the decode loop appends at row `realLength` onward. Adds a one-hot
    /// `logitsSelectMask` at `realLength-1` (the start-speech row) so the graph
    /// reads the seed logits without a dynamic gather.
    struct AssembledFront: Sendable {
        var inputsEmbeds: [Float]      // flat (maxLen * hidden), real at front
        var positionIds: [Int32]       // (maxLen): reals→0..realLength-1, pad→0
        var keyPaddingMask: [Int32]    // (maxLen): 1 real, 0 pad
        var logitsSelectMask: [Float]  // (maxLen): one-hot at realLength-1
        var realLength: Int            // T_real = 1 + T_cond + T_text + 1
    }

    func assembleFrontAligned(textTokens: [Int32], conds: Conditionals) -> AssembledFront {
        let condTokens = conds.condPromptSpeechTokens
        let tCond = condTokens.count
        let textBudget = max(0, maxLen - tCond - 2)
        let usedText = textTokens.count > textBudget
            ? Array(textTokens.prefix(textBudget))
            : textTokens
        let realLength = 1 + tCond + usedText.count + 1

        var real: [Float] = []
        real.reserveCapacity(realLength * hidden)
        real.append(contentsOf: spkrProjection.project(conds.speakerEmb))
        for t in condTokens { speechEmb.appendRow(Int(t), to: &real) }
        for t in usedText { textEmb.appendRow(Int(t), to: &real) }
        speechEmb.appendRow(Constants.speechStartToken, to: &real)

        var inputsEmbeds = [Float](repeating: 0, count: maxLen * hidden)
        for i in 0..<real.count { inputsEmbeds[i] = real[i] }  // real at the front

        var positionIds = [Int32](repeating: 0, count: maxLen)
        var keyPaddingMask = [Int32](repeating: 0, count: maxLen)
        var logitsSelectMask = [Float](repeating: 0, count: maxLen)
        for j in 0..<realLength {
            positionIds[j] = Int32(j)
            keyPaddingMask[j] = 1
        }
        logitsSelectMask[realLength - 1] = 1

        return AssembledFront(
            inputsEmbeds: inputsEmbeds,
            positionIds: positionIds,
            keyPaddingMask: keyPaddingMask,
            logitsSelectMask: logitsSelectMask,
            realLength: realLength
        )
    }

    /// Slices the real KV out of the padded `(48, 1, 16, maxLen, 64)` cache.
    ///
    /// Pad rows occupy the **front** along dim 3, so the real KV is the tail
    /// `[nPad ..< maxLen)`. Returns a flat `(48 * 16 * realLength * 64)` array in
    /// plane-major order — exactly the layout the decode loop slices per layer as
    /// `(1, 16, realLength, 64)`.
    static func sliceRealKV(
        paddedCache: [Float],
        maxLen: Int,
        nPad: Int,
        planes: Int = 2 * Constants.gpt2Layers,
        heads: Int = Constants.gpt2Heads,
        headDim: Int = Constants.gpt2HeadDim
    ) -> [Float] {
        let realLength = maxLen - nPad
        var out = [Float](repeating: 0, count: planes * heads * realLength * headDim)
        var w = 0
        paddedCache.withUnsafeBufferPointer { src in
            for p in 0..<planes {
                for h in 0..<heads {
                    // Source row base for (plane p, head h, pos 0); dim1 == 1 collapses.
                    let base = ((p * heads + h) * maxLen + nPad) * headDim
                    let n = realLength * headDim
                    for k in 0..<n { out[w + k] = src[base + k] }
                    w += n
                }
            }
        }
        return out
    }
}
