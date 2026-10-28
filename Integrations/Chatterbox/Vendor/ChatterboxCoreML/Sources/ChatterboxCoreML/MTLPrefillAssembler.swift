import Foundation

/// Host-side assembly for the **multilingual** batch-2 CFG prefill
/// (`T3LM` "prefill" function). Builds the
/// front-aligned `inputs_embeds (2, W, 1024)` plus the position / select tensors.
///
/// Official regular V3 inference uses cond + text + BOS0 + BOS0 in both lanes.
/// With CFG, lane 1 zeroes lexical text BEFORE learned text positions are added.
/// Both BOS rows share speech position zero; generated speech begins at position one.
///
///   cond   = [spkr(1); perceiver(prompt→32); emotion(1)]   (CondBlockBuilder)
///   text   = text_emb(tok) + text_pos_emb(0…n_text−1)      (learned input pos-emb)
///   BOS    = speech_emb(6561) + speech_pos_emb(0)
///
/// Real rows occupy the front `[0..realLength)`, pad at the tail; decode appends
/// from row `realLength`. Free of CoreML so the contract is unit-testable.
struct MTLPrefillAssembler: Sendable {
    let textEmb: EmbeddingTable        // (2454, 1024)
    let textPosEmb: EmbeddingTable     // (≥max_text, 1024)
    let speechEmb: SpeechEmbedding     // (8194, 1024)
    let speechPosEmb: EmbeddingTable   // (≥max_speech, 1024)
    let condBuilder: CondBlockBuilder
    let window: Int
    let hidden: Int
    private let conditioningCache = ConditioningBlockCache()

    init(textEmb: EmbeddingTable, textPosEmb: EmbeddingTable,
         speechEmb: SpeechEmbedding, speechPosEmb: EmbeddingTable,
         condBuilder: CondBlockBuilder,
         window: Int = MultilingualConstants.window,
         hidden: Int = MultilingualConstants.hidden) {
        self.textEmb = textEmb; self.textPosEmb = textPosEmb
        self.speechEmb = speechEmb; self.speechPosEmb = speechPosEmb
        self.condBuilder = condBuilder
        self.window = window; self.hidden = hidden
    }

    struct Assembled: Sendable {
        var inputsEmbeds: [Float]      // flat (2 * W * hidden), C-order (lane outermost)
        var positionIds: [Int32]       // (W): reals→0…realLength-1, pad→0
        var logitsSelectMask: [Float]  // (W): one-hot at realLength-1 (BOS row)
        var realLength: Int            // T_cond(34) + T_text + 2(BOS)
        var condRows: Int              // 34
        var conditioningCacheHit: Bool
    }

    /// Builds the conditioning-prompt speech embedding the Perceiver consumes:
    /// `speech_emb(tok) + speech_pos_emb(i)` for i in 0…N-1, flat `(N, 1024)`.
    func condPromptSpeechEmb(_ promptTokens: [Int32]) -> [Float] {
        var out = [Float](repeating: 0, count: promptTokens.count * hidden)
        for (i, t) in promptTokens.enumerated() {
            let se = speechEmb.row(Int(t))
            let pe = speechPosEmb.row(i)
            let base = i * hidden
            for d in 0..<hidden { out[base + d] = se[d] + pe[d] }
        }
        return out
    }

    func assemble(textTokens: [Int32], conds: Conditionals, exaggeration: Float, cfgWeight: Float = 0.5) -> Assembled {
        let condRows = MultilingualConstants.condRows
        // The runner rejects oversized input before assembly; never trim source text.
        let textBudget = max(0, window - condRows - 2)
        precondition(textTokens.count <= textBudget)
        let usedText = textTokens
        let nText = usedText.count
        let realLength = condRows + nText + 2

        // 1. cond block (34, 1024) — shared by both lanes.
        let promptTokens = conds.condPromptSpeechTokens
        let cached = conditioningCache.value(for: .init(
            speaker: conds.speakerEmb, promptTokens: promptTokens, exaggeration: exaggeration)) {
                condBuilder.build(
                    speakerEmb: conds.speakerEmb,
                    condPromptSpeechEmb: condPromptSpeechEmb(promptTokens),
                    promptLen: promptTokens.count,
                    exaggeration: exaggeration)
            }
        let cond = cached.values

        var lexical = [Float](repeating: 0, count: nText * hidden)
        var positions = [Float](repeating: 0, count: nText * hidden)
        for (p, t) in usedText.enumerated() {
            let text = textEmb.row(Int(t)), position = textPosEmb.row(p)
            for d in 0..<hidden {
                lexical[p * hidden + d] = text[d]
                positions[p * hidden + d] = position[d]
            }
        }
        let bosE = speechEmb.row(MultilingualConstants.speechStartToken)
        let bosP = speechPosEmb.row(0)
        var bos = [Float](repeating: 0, count: hidden)
        for d in 0..<hidden { bos[d] = bosE[d] + bosP[d] }
        let packed = CanonicalMTLPrefillPacker.pack(conditioning: cond, lexicalText: lexical,
            textPositions: positions, bos: bos, window: window, hidden: hidden, useCFG: cfgWeight > 0)

        return Assembled(
            inputsEmbeds: packed.inputsEmbeds,
            positionIds: packed.positionIds,
            logitsSelectMask: packed.logitsSelectMask,
            realLength: realLength,
            condRows: condRows,
            conditioningCacheHit: cached.hit)
    }
}
