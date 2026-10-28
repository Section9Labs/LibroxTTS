import CoreML
import Foundation

/// Multilingual multifunction CoreML runner (the multilingual `T3LM.mlpackage`):
/// batch-2 CFG prefill + decode against a
/// shared `MLState`, with host-side CFG-combine and the learned speech position
/// embedding added per step.
///
/// Differs from the turbo `T3LMRunner` in three ways:
///  - **batch=2** — row 0 conditional, row 1 unconditional (text zeroed). Every
///    predict returns `logits (2, V)`; the host combines
///    `cond + cfgWeight·(cond − uncond)` before sampling.
///  - **cond block** is the 34-row spkr+perceiver+emotion prefix (`CondBlockBuilder`),
///    not raw cond speech-token rows.
///  - **learned input pos-emb** — the LLaMA backbone uses RoPE *and* a learned
///    `speech_pos_emb`; the latter is added host-side to each decode token
///    (`get_fixed_embedding(step+1)`), since the CoreML graph takes `inputs_embeds`.
///
/// Contract (matches the converter):
///   prefill: inputs_embeds (2,W,1024) f16, position_ids (1,W) i32,
///            attn_mask (1,1,W,W) f16, write_mask (W,1) f16,
///            logits_select_mask (1,W,1) f16 → logits (2,V)
///   decode:  inputs_embeds (2,1,1024) f16, position_ids (1,1) i32,
///            update_mask (MAX,1) f16, attn_mask (1,1,1,MAX) f16 → logits (2,V)
final class MTLT3LMRunner: @unchecked Sendable {
    private let prefillModel: MLModel
    private let decodeModel: MLModel
    var selectedComputeUnits: MLComputeUnits { prefillModel.configuration.computeUnits }
    private let assembler: MTLPrefillAssembler
    private let speechEmb: SpeechEmbedding
    private let speechPosEmb: EmbeddingTable
    private let hidden = MultilingualConstants.hidden
    private let vocab = MultilingualConstants.speechVocabSize

    let maxLen: Int
    let maxSeq: Int

    private static let maskNeg: Float = -1.0e4

    init(contentsOf url: URL, hostTablesDir: URL, computeUnits override: MLComputeUnits? = nil) throws {
        // Compute-unit chain: try ANE → GPU → CPU; the loop below catches a failed
        // load and falls through, so a model that can't place on the ANE self-heals
        // to GPU. An explicit `CHATTERBOX_DECODE_CU` pins one unit with NO fallback
        // (for A/B testing).
        //
        // ROOT CAUSE (resolved 2026-06-20, device-verified on iPhone 17 Pro Max /
        // iOS 26.5.1): the earlier iOS ANE-load failure ("ANE model load has failed
        // for on-device compiled macho. Must re-compile the E5 bundle. (13)" →
        // "functionName must be nil unless ML Program") was the **prefill function**
        // specifically. At FP16 the 30-layer prefill graph (q_len=512, ~980 MB
        // weights) exceeds an ANE execution-plan/macho weight limit — it fails to
        // build the plan (standalone error code -14); decode (q_len=1, same size)
        // always loaded on the ANE fine. **8-bit palettizing the T3LM halves the
        // weights to ~500 MB, bringing prefill under the limit — both functions then
        // load on the ANE** (LoadProbe A–F matrix: FP16 prefill ❌ / 8-bit prefill ✅
        // standalone AND multifunction). So the shipped multilingual T3LM is 8-bit
        // and `.all` routes to the ANE on iOS; no platform split is needed. The
        // try/catch still protects an unexpected too-large model (it just costs a
        // one-time ANE AOT compile before the GPU fallback).
        // A non-nil `override` (the app's whole-pipeline ANE toggle) pins one CU with
        // NO fallback, exactly like `CHATTERBOX_DECODE_CU` — it takes precedence over
        // the env, which takes precedence over the `.all→GPU→CPU` self-healing chain.
        let explicit: MLComputeUnits?
        if let override {
            explicit = override
        } else {
            switch ProcessInfo.processInfo.environment["CHATTERBOX_DECODE_CU"]?.lowercased() {
            case "cpu": explicit = .cpuOnly
            case "cpuandgpu", "gpu": explicit = .cpuAndGPU
            case "cpuandne", "ane", "ne": explicit = .cpuAndNeuralEngine
            case "all": explicit = .all
            default: explicit = nil
            }
        }
        let defaultChain: [MLComputeUnits] = [.all, .cpuAndGPU, .cpuOnly]
        let chain: [MLComputeUnits] = explicit.map { [$0] } ?? defaultChain
        Log.load.notice("[load:mtl-t3lm] start url=\(url.path, privacy: .public) cuChain=\(chain.map { String(describing: $0) }.joined(separator: ">"), privacy: .public)")

        func loadBoth(_ unit: MLComputeUnits) throws -> (MLModel, MLModel) {
            let pcfg = MLModelConfiguration(); pcfg.computeUnits = unit; pcfg.functionName = "prefill"
            let p = try MLModel(contentsOf: url, configuration: pcfg)
            let dcfg = MLModelConfiguration(); dcfg.computeUnits = unit; dcfg.functionName = "decode"
            let d = try MLModel(contentsOf: url, configuration: dcfg)
            return (p, d)
        }
        var loaded: (MLModel, MLModel)?
        var lastError: Error?
        for unit in chain {
            do {
                loaded = try loadBoth(unit)
                Log.load.notice("[load:mtl-t3lm] loaded on \(String(describing: unit), privacy: .public)")
                break
            } catch {
                lastError = error
                Log.load.error("[load:mtl-t3lm] load on \(String(describing: unit), privacy: .public) FAILED: \(error.localizedDescription, privacy: .public) — trying next CU")
            }
        }
        guard let (p, d) = loaded else {
            throw lastError ?? ChatterboxError.invalidModelOutput("MTL T3LM failed to load on any compute unit")
        }
        prefillModel = p
        decodeModel = d

        maxLen = prefillModel.modelDescription.inputDescriptionsByName["inputs_embeds"]?
            .multiArrayConstraint?.shape.map { $0.intValue }.dropFirst().first ?? MultilingualConstants.window
        maxSeq = decodeModel.modelDescription.inputDescriptionsByName["update_mask"]?
            .multiArrayConstraint?.shape.first?.intValue ?? MultilingualConstants.maxSeq

        // Host tables for assembly + per-step pos-emb.
        let textEmb = try EmbeddingTable(contentsOf: hostTablesDir.appendingPathComponent("text_emb.npy"), name: "text_emb")
        let textPosEmb = try EmbeddingTable(contentsOf: hostTablesDir.appendingPathComponent("text_pos_emb.npy"), name: "text_pos_emb")
        self.speechEmb = try SpeechEmbedding(contentsOf: hostTablesDir.appendingPathComponent("speech_emb.npy"))
        self.speechPosEmb = try EmbeddingTable(contentsOf: hostTablesDir.appendingPathComponent("speech_pos_emb.npy"), name: "speech_pos_emb")
        let condBuilder = try CondBlockBuilder(dir: hostTablesDir)
        self.assembler = MTLPrefillAssembler(
            textEmb: textEmb, textPosEmb: textPosEmb,
            speechEmb: speechEmb, speechPosEmb: speechPosEmb,
            condBuilder: condBuilder, window: maxLen, hidden: hidden)
    }

    struct Output {
        let tokens: [Int]
        let prefillLength: Int
        let prefillTime: TimeInterval
        let decodeTime: TimeInterval
        let seedLogits: [Float]   // CFG-combined seed logits (diagnostics/parity)
        let hostAssemblyTime: TimeInterval
        let conditioningCacheHit: Bool
        let decodeStepTimings: DecodeStepTimings?
    }

    func generate(textTokens: [Int32], conds: Conditionals, options: GenerationOptions) throws -> Output {
        #if arch(arm64)
        try Task.checkCancellation()
        try Self.validateContext(textTokenCount: textTokens.count, prefillWindow: maxLen,
                                 maxSequence: maxSeq, maxNewTokens: options.maxTokens)
        let assemblyStart = ContinuousClock.now
        let asm = assembler.assemble(textTokens: textTokens, conds: conds, exaggeration: options.exaggeration, cfgWeight: options.cfgWeight)
        let assemblyDuration = assemblyStart.duration(to: .now).components
        let hostAssemblyTime = Double(assemblyDuration.seconds) + Double(assemblyDuration.attoseconds) / 1e18
        Log.pipeline.debug("[assembly:mtl] host \(hostAssemblyTime, format: .fixed(precision: 6), privacy: .public)s conditioningCacheHit=\(asm.conditioningCacheHit, privacy: .public)")
        let realLength = asm.realLength
        let cfg = options.cfgWeight

        let state = prefillModel.makeState()

        // --- Prefill ---
        let attnMaskP = try buildPrefillAttnMask(realLength: realLength)
        let writeMask = try buildWriteMask(realLength: realLength)
        let prefillProvider = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLMultiArray.float16(asm.inputsEmbeds, shape: [2, maxLen, hidden]),
            "position_ids": MLMultiArray.int32(asm.positionIds, shape: [1, maxLen]),
            "attn_mask": attnMaskP,
            "write_mask": writeMask,
            "logits_select_mask": MLMultiArray.float16(asm.logitsSelectMask, shape: [1, maxLen, 1]),
        ])
        let tPre = Date()
        try Task.checkCancellation()
        let prefillOut = try predictTrapping(prefillModel, from: prefillProvider, label: "MTL T3LM prefill") {
            try $0.prediction(from: $1, using: state, options: MLPredictionOptions())
        }
        let prefillTime = Date().timeIntervalSince(tPre)
        guard let seedArr = prefillOut.featureValue(for: "logits")?.multiArrayValue else {
            throw ChatterboxError.invalidModelOutput("MTL T3LM prefill missing 'logits'")
        }
        let seedLogits = cfgCombine(seedArr.toFloatArrayAnyPrecision(), cfg: cfg)

        // --- Decode loop ---
        var sampler = Sampler(options: options)
        var generated: [Int] = []
        var stoppedNaturally = false

        let updateMask = try MLMultiArray(shape: [NSNumber(value: maxSeq), 1], dataType: .float16)
        let attnMaskD = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: maxSeq)], dataType: .float16)
        let posArr = try MLMultiArray(shape: [1, 1], dataType: .int32)
        updateMask.withUnsafeMutableBytes { raw, _ in
            let um = raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)
            for i in 0..<maxSeq { um[i] = 0 }
        }
        attnMaskD.withUnsafeMutableBytes { raw, _ in
            let am = raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)
            for i in 0..<maxSeq { am[i] = i < realLength ? 0 : Float16(Self.maskNeg) }
        }
        var prevPos = -1
        var nextToken = sampler.sample(logits: seedLogits, previous: generated, minTokensReached: false)

        let tDec = Date()
        let profileDecode = ProcessInfo.processInfo.environment["CHATTERBOX_PROFILE_DECODE"] == "1"
        var stepTimings = DecodeStepTimings()
        func elapsed(_ start: ContinuousClock.Instant?) -> TimeInterval {
            guard let start else { return 0 }
            let components = start.duration(to: .now).components
            return Double(components.seconds) + Double(components.attoseconds) / 1e18
        }
        for step in 0..<options.maxTokens {
            try Task.checkCancellation()
            if nextToken == MultilingualConstants.speechStopToken && generated.count >= options.minTokens {
                stoppedNaturally = true; break
            }
            let writePos = realLength + step
            guard writePos < maxSeq else {
                throw ChatterboxError.invalidModelOutput("T3 context overflow at position \(writePos); refusing partial narration")
            }
            let preparationStart = profileDecode ? ContinuousClock.now : nil
            generated.append(nextToken)

            updateMask.withUnsafeMutableBytes { raw, _ in
                let um = raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)
                if prevPos >= 0 { um[prevPos] = 0 }
                um[writePos] = 1
            }
            prevPos = writePos
            attnMaskD.withUnsafeMutableBytes { raw, _ in
                raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)[writePos] = 0
            }
            posArr.withUnsafeMutableBytes { raw, _ in
                raw.baseAddress!.bindMemory(to: Int32.self, capacity: 1)[0] = Int32(writePos)
            }
            // inputs_embeds (2,1,hidden): speech_emb(tok)+speech_pos_emb(step+1), both lanes.
            let embeds = try MLMultiArray.float16(decodeEmbed(token: nextToken, speechPos: step + 1), shape: [2, 1, hidden])
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "inputs_embeds": embeds, "position_ids": posArr,
                "update_mask": updateMask, "attn_mask": attnMaskD,
            ])
            if profileDecode { stepTimings.inputPreparationSeconds += elapsed(preparationStart) }
            let predictionStart = profileDecode ? ContinuousClock.now : nil
            let out = try predictTrapping(decodeModel, from: provider, label: "MTL T3LM decode") {
                try $0.prediction(from: $1, using: state, options: MLPredictionOptions())
            }
            if profileDecode { stepTimings.predictionSeconds += elapsed(predictionStart) }
            let logitsStart = profileDecode ? ContinuousClock.now : nil
            guard let logitsArr = out.featureValue(for: "logits")?.multiArrayValue else {
                throw ChatterboxError.invalidModelOutput("MTL T3LM decode missing 'logits'")
            }
            let logits = cfgCombine(logitsArr.toFloatArrayAnyPrecision(), cfg: cfg)
            if profileDecode { stepTimings.logitsCopyAndCFGSeconds += elapsed(logitsStart) }
            let samplingStart = profileDecode ? ContinuousClock.now : nil
            nextToken = sampler.sample(logits: logits, previous: generated, minTokensReached: generated.count >= options.minTokens)
            if profileDecode {
                stepTimings.samplingSeconds += elapsed(samplingStart)
                stepTimings.iterations += 1
            }
        }
        let decodeTime = Date().timeIntervalSince(tDec)
        let msPerTok = generated.isEmpty ? 0 : decodeTime * 1000 / Double(generated.count)
        Log.decode.debug("[decode:mtl-t3lm] tokens=\(generated.count, privacy: .public) ms/tok=\(msPerTok, format: .fixed(precision: 2), privacy: .public) stopped=\(stoppedNaturally, privacy: .public) prefillLen=\(realLength, privacy: .public)")
        if profileDecode {
            Log.decode.notice("[decode-profile] iterations=\(stepTimings.iterations, privacy: .public) input=\(stepTimings.inputPreparationSeconds, privacy: .public)s prediction=\(stepTimings.predictionSeconds, privacy: .public)s logitsCFG=\(stepTimings.logitsCopyAndCFGSeconds, privacy: .public)s sample=\(stepTimings.samplingSeconds, privacy: .public)s total=\(decodeTime, privacy: .public)s maxSeq=\(self.maxSeq, privacy: .public)")
        }
        return Output(tokens: generated, prefillLength: realLength,
                      prefillTime: prefillTime, decodeTime: decodeTime, seedLogits: seedLogits,
                      hostAssemblyTime: hostAssemblyTime, conditioningCacheHit: asm.conditioningCacheHit,
                      decodeStepTimings: profileDecode ? stepTimings : nil)
        #else
        _ = (textTokens, conds, options)
        preconditionFailure("MTLT3LMRunner requires arm64 (Apple Silicon)")
        #endif
    }

    /// Admission uses the complete tokenized text and requested generation cap.
    /// It runs before assembly (which historically trimmed) or state allocation.
    static func validateContext(textTokenCount: Int, prefillWindow: Int,
                                maxSequence: Int, maxNewTokens: Int) throws {
        let fixedRows = MultilingualConstants.condRows + 2 // voice prefix + two position-0 BOS rows
        guard textTokenCount >= 0, prefillWindow >= fixedRows,
              textTokenCount <= prefillWindow - fixedRows else {
            throw ChatterboxError.invalidModelOutput("T3 text exceeds prefill budget; replan the source unit instead of truncating")
        }
        let realLength = fixedRows + textTokenCount
        guard maxNewTokens > 0, maxSequence >= realLength,
              maxNewTokens <= maxSequence - realLength else {
            throw ChatterboxError.invalidModelOutput("T3 context overflow: prefix \(realLength) + generation cap \(maxNewTokens) exceeds \(maxSequence); replan the source unit")
        }
    }

    /// `cond + cfg·(cond − uncond)` over `logits (2, V)` flat (lane outermost).
    private func cfgCombine(_ logits2: [Float], cfg: Float) -> [Float] {
        var out = [Float](repeating: 0, count: vocab)
        for i in 0..<vocab {
            let c = logits2[i], u = logits2[vocab + i]
            out[i] = c + cfg * (c - u)
        }
        return out
    }

    /// `speech_emb(token) + speech_pos_emb(speechPos)`, duplicated for both CFG lanes.
    private func decodeEmbed(token: Int, speechPos: Int) -> [Float] {
        let se = speechEmb.row(token)
        let pe = speechPosEmb.row(speechPos)
        var lane = [Float](repeating: 0, count: hidden)
        for d in 0..<hidden { lane[d] = se[d] + pe[d] }
        return lane + lane   // (2, 1, hidden)
    }

    // MARK: - masks (shared across lanes; identical to the turbo contract)

    private func buildPrefillAttnMask(realLength: Int) throws -> MLMultiArray {
        #if arch(arm64)
        let W = maxLen
        let arr = try MLMultiArray(shape: [1, 1, NSNumber(value: W), NSNumber(value: W)], dataType: .float16)
        arr.withUnsafeMutableBytes { raw, _ in
            let p = raw.baseAddress!.bindMemory(to: Float16.self, capacity: W * W)
            for i in 0..<W {
                let rowBase = i * W
                for j in 0..<W {
                    if i == j { p[rowBase + j] = 0; continue }
                    var v: Float = 0
                    if j > i { v += Self.maskNeg }
                    if j >= realLength { v += Self.maskNeg }
                    p[rowBase + j] = Float16(v)
                }
            }
        }
        return arr
        #else
        preconditionFailure("arm64 only")
        #endif
    }

    private func buildWriteMask(realLength: Int) throws -> MLMultiArray {
        #if arch(arm64)
        let W = maxLen
        let arr = try MLMultiArray(shape: [NSNumber(value: W), 1], dataType: .float16)
        arr.withUnsafeMutableBytes { raw, _ in
            let p = raw.baseAddress!.bindMemory(to: Float16.self, capacity: W)
            for i in 0..<W { p[i] = i < realLength ? 1 : 0 }
        }
        return arr
        #else
        preconditionFailure("arm64 only")
        #endif
    }
}
