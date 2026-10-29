import CoreML
import Foundation

/// Single multifunction CoreML model running both prefill and decode against a
/// shared `MLState` (`T3LM.mlpackage` — `--stage multifunction`).
///
/// Replaces the legacy two-model path (`T3Prefill` + `T3Decode` or `OrtDecoder`):
/// the converter merges prefill and decode into one weight- and state-sharing
/// package via `ct.utils.save_multifunction`, and both functions run fully
/// ANE-resident on iPhone iOS 18+ (validated on device against a CPU baseline).
///
/// Serves both GPT-2 English variants — **turbo** (24×1024) and **nano**
/// (12×768). Nothing here is hard-coded to a depth or width: `H` below is read
/// from the loaded graph and every host-side table is checked against it in
/// `init`.
///
/// Contract (matches the patched `_T3PrefillStatefulWrapper` /
/// `_T3DecodeStatefulWrapper`), `H` = hidden width (turbo 1024, nano 768):
///
///   `prefill` function, q = MAX (front-aligned, pad at the tail):
///     inputs_embeds      (1, MAX, H)   f16
///     position_ids       (1, MAX)       i32
///     attn_mask          (1, 1, MAX, MAX) f16  — host-built additive (causal +
///                                                  pad-column, diagonal zeroed)
///     write_mask         (MAX, 1)       f16    — host-built (1 real, 0 pad);
///                                                used in-graph to zero pad K/V
///                                                before writing the shared cache
///     logits_select_mask (1, MAX, 1)    f16    — one-hot at realLength-1
///   → logits (1, 6563) f16                       — at the start-speech row
///
///   `decode` function, q = 1:
///     inputs_embeds   (1, 1, H)     f16
///     position_ids    (1, 1)       i32
///     update_mask     (MAX_SEQ, 1) f16   — one-hot at the current write row
///     attn_mask       (1, 1, 1, MAX_SEQ) f16 — 0 for written, mask_neg elsewhere
///   → logits (1, 6563) f16
///
///   State (shared): keyCache, valueCache, both `(MAX_SEQ, layers*heads*headDim)` f16.
///
/// Lifting the masks out of the model (host-built instead of in-graph from
/// `key_padding_mask`) is what makes the stateful q>1 prefill ANE-compilable —
/// the in-graph mask pattern (`(const_causal + (1-pad_var)·mask_neg) · (1-eye)`)
/// triggers `std::bad_cast` in CoreML's MIL→EIR translator for ≥24 stateful SDPA
/// layers and was the root cause behind the prior dead-end-#1 conclusion.
///
/// Even with the host-built additive `attn_mask` lifted into the graph, on
/// iPhone ANE the fused SDPA kernel for q≫1 silently drops that input and only
/// honors a built-in causal flag. The prefill wrapper now **decomposes SDPA
/// manually** (matmul + add + softmax + matmul) so the ANE compiler cannot
/// pattern-match against the fused kernel and must honor the explicit mask.
/// Confirmed on iPhone ANE against a Mac Python CPU baseline.
final class T3LMRunner: @unchecked Sendable {
    private let prefillModel: MLModel
    private let decodeModel: MLModel
    var selectedComputeUnits: MLComputeUnits { prefillModel.configuration.computeUnits }
    private let assembler: PrefillAssembler
    private let speechEmb: SpeechEmbedding

    /// Prefill window width (read from the model's `inputs_embeds` shape).
    let maxLen: Int
    /// Shared KV-cache width / decode horizon (read from `update_mask` shape).
    let maxSeq: Int
    /// Hidden width, read from the model — turbo 1024, nano 768. NEVER a constant:
    /// feeding a graph host-assembled embeddings of the wrong width does not fail,
    /// it produces garbage audio, so it is derived and then cross-checked in `init`.
    let hidden: Int

    /// FP16-safe additive mask for not-yet-written positions (matches converter's
    /// `mask_neg`; -1e9 saturates to -inf → NaN softmax in fp16).
    private static let maskNeg: Float = -1.0e4

    init(
        contentsOf url: URL,
        speechEmb: SpeechEmbedding,
        textEmb: EmbeddingTable,
        spkrProjection: SpeakerProjection,
        computeUnits override: MLComputeUnits? = nil
    ) throws {
        // Compute units: `.all` picks ANE on iPhone and GPU on Mac. The on-device
        // probe verified both T3LM functions are fully ANE-resident with `.all`
        // (831/1117 ANE ops, 0 nil). An explicit `override` (the app's whole-pipeline
        // ANE toggle) wins over `CHATTERBOX_DECODE_CU`, which wins over the `.all`
        // default — forcing `.cpuAndNeuralEngine` moves the non-ANE segments off the
        // GPU (background-legal) since `ProcessInfo`'s env snapshot can't be set post-launch.
        let cu: MLComputeUnits
        if let override {
            cu = override
        } else {
            switch ProcessInfo.processInfo.environment["CHATTERBOX_DECODE_CU"]?.lowercased() {
            case "cpu": cu = .cpuOnly
            case "cpuandgpu", "gpu": cu = .cpuAndGPU
            case "cpuandne", "ane", "ne": cu = .cpuAndNeuralEngine
            default: cu = .all
            }
        }

        Log.load.notice("[load:t3lm] start url=\(url.path, privacy: .public) cu=\(String(describing: cu), privacy: .public)")
        // Surface the file's basic shape so a stale/wrong-type model is obvious in
        // the log (the "must be nil unless ML Program" error means the loaded file
        // isn't an ML Program — typically an obsolete cache that needs re-download).
        if let manifest = T3LMRunner.peekManifest(at: url) {
            Log.load.notice("[load:t3lm] manifest=\(manifest, privacy: .public)")
        } else {
            Log.load.notice("[load:t3lm] manifest=<missing or unreadable>")
        }

        let pcfg = MLModelConfiguration()
        pcfg.computeUnits = cu
        pcfg.functionName = "prefill"
        do {
            prefillModel = try MLModel(contentsOf: url, configuration: pcfg)
            Log.load.notice("[load:t3lm] prefill function loaded OK")
        } catch {
            Log.load.error("[load:t3lm] prefill function load FAILED at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let dcfg = MLModelConfiguration()
        dcfg.computeUnits = cu
        dcfg.functionName = "decode"
        do {
            decodeModel = try MLModel(contentsOf: url, configuration: dcfg)
            Log.load.notice("[load:t3lm] decode function loaded OK")
        } catch {
            Log.load.error("[load:t3lm] decode function load FAILED at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // The prefill `inputs_embeds` shape (1, W, H) gives both the window and the
        // hidden width; MAX_SEQ comes from the decode `update_mask` shape (MAX_SEQ, 1).
        let embedsShape = prefillModel.modelDescription
            .inputDescriptionsByName["inputs_embeds"]?
            .multiArrayConstraint?.shape.map { $0.intValue }
        let w = embedsShape?.dropFirst().first ?? 512
        let h = embedsShape?.last ?? Constants.gpt2Hidden
        let ms = decodeModel.modelDescription
            .inputDescriptionsByName["update_mask"]?
            .multiArrayConstraint?.shape.first?.intValue ?? 1536
        maxLen = w
        maxSeq = ms
        hidden = h
        Log.load.notice("[load:t3lm] maxLen=\(w, privacy: .public) maxSeq=\(ms, privacy: .public) hidden=\(h, privacy: .public)")

        try T3LMRunner.validateTableWidths(
            graphHidden: h, speechEmb: speechEmb, textEmb: textEmb, spkrProjection: spkrProjection)

        self.speechEmb = speechEmb
        self.assembler = PrefillAssembler(
            speechEmb: speechEmb, textEmb: textEmb,
            spkrProjection: spkrProjection, maxLen: w, hidden: h
        )
    }

    /// The host tables and the graph must agree on the width. A turbo `.npy` set paired
    /// with a nano `T3LM` (or vice versa) is a *silent* failure otherwise: CoreML accepts
    /// the flat buffer and the pipeline emits noise instead of throwing. Fail the load.
    ///
    /// Split out of `init` only so it is reachable offline — inside `init` it sits behind
    /// two `MLModel` loads, so it could not be unit-tested without a real `.mlpackage`.
    static func validateTableWidths(
        graphHidden h: Int,
        speechEmb: SpeechEmbedding,
        textEmb: EmbeddingTable,
        spkrProjection: SpeakerProjection
    ) throws {
        guard speechEmb.hidden == h, textEmb.cols == h, spkrProjection.outDim == h else {
            throw ChatterboxError.shapeMismatch(
                "T3LM graph hidden=\(h) but host tables are speech_emb=\(speechEmb.hidden), "
                + "text_emb=\(textEmb.cols), spkr_enc out=\(spkrProjection.outDim) — the model and the "
                + ".npy tables are from different variants (turbo=\(Constants.gpt2Hidden), "
                + "nano=\(NanoConstants.hidden)); re-download the model dir")
        }
    }

    /// One generated chunk: speech tokens (excluding stop) and per-stage timings.
    struct Output {
        let tokens: [Int]
        let prefillLength: Int
        let prefillTime: TimeInterval
        let decodeTime: TimeInterval
    }

    /// Runs prefill into a fresh shared `MLState`, then the autoregressive decode
    /// loop on the same state. Returns the generated speech tokens (excluding the
    /// stop token) and per-stage wall-clock.
    func generate(
        textTokens: [Int32],
        conds: Conditionals,
        options: GenerationOptions
    ) throws -> Output {
        #if arch(arm64)
        let assembled = assembler.assembleFrontAligned(textTokens: textTokens, conds: conds)
        let realLength = assembled.realLength

        // Fresh shared state — both prefill and decode operate on this one buffer.
        let state = prefillModel.makeState()
        Self.logStateSum(state, label: "[decode:t3lm] state BEFORE prefill")

        // --- Prefill ---
        let attnMaskP = try buildPrefillAttnMask(realLength: realLength)
        let writeMask = try buildWriteMask(realLength: realLength)
        // Sanity: confirm inputs are non-degenerate. A degenerate (all-zero)
        // inputs_embeds would imply the host-assembly broke; equally important,
        // a zeroed state AFTER prefill means the prefill write_state didn't land
        // in the shared MLState (e.g., the two MLModel instances aren't sharing).
        let embedsAbsSum: Float = assembled.inputsEmbeds.reduce(0) { $0 + abs($1) }
        let lsmSum: Float = assembled.logitsSelectMask.reduce(0, +)
        Log.decode.debug("[decode:t3lm] inputs_embeds |sum|=\(embedsAbsSum, privacy: .public) lsm_sum=\(lsmSum, privacy: .public) realLength=\(realLength, privacy: .public)")

        let prefillProvider = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLMultiArray.float16(assembled.inputsEmbeds, shape: [1, maxLen, hidden]),
            "position_ids": MLMultiArray.int32(assembled.positionIds, shape: [1, maxLen]),
            "attn_mask": attnMaskP,
            "write_mask": writeMask,
            "logits_select_mask": MLMultiArray.float16(assembled.logitsSelectMask, shape: [1, maxLen, 1]),
        ])
        let tPre = Date()
        let prefillOut = try predictTrapping(prefillModel, from: prefillProvider, label: "T3LM prefill") {
            try $0.prediction(from: $1, using: state, options: MLPredictionOptions())
        }
        let prefillTime = Date().timeIntervalSince(tPre)
        Self.logStateSum(state, label: "[decode:t3lm] state AFTER prefill")
        guard let seedArr = prefillOut.featureValue(for: "logits")?.multiArrayValue else {
            throw ChatterboxError.invalidModelOutput("T3LM prefill missing 'logits'")
        }
        let seedLogits = try seedArr.toFloatArrayAnyPrecision()
        Self.logTopK(seedLogits, label: "[decode:t3lm] seed top-5", count: 5)

        // --- Decode loop ---
        var sampler = Sampler(options: options)
        var generated: [Int] = []
        var stoppedNaturally = false

        // Reused per-step inputs — mutate one element each step rather than
        // reallocate (keeps per-`predict` dispatch overhead down).
        let updateMask = try MLMultiArray(shape: [NSNumber(value: maxSeq), 1], dataType: .float16)
        let attnMaskD = try MLMultiArray(shape: [1, 1, 1, NSNumber(value: maxSeq)], dataType: .float16)
        let posArr = try MLMultiArray(shape: [1, 1], dataType: .int32)

        // update_mask starts all-zero; attn_mask: 0 for prefill rows already
        // written ([0..realLength-1]), masked elsewhere. Each decode step unmasks
        // its newly written row. Per-step mutations are scoped inside
        // `getMutableBytesWithHandler` closures so the CVPixelBuffer backing these
        // ANE-resident arrays isn't held locked between predicts.
        updateMask.withUnsafeMutableBytes { raw, _ in
            let um = raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)
            for i in 0..<maxSeq { um[i] = 0 }
        }
        attnMaskD.withUnsafeMutableBytes { raw, _ in
            let am = raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)
            for i in 0..<maxSeq { am[i] = i < realLength ? 0 : Float16(Self.maskNeg) }
        }
        var prevPos = -1

        var nextToken = sampler.sample(
            logits: seedLogits, previous: generated, minTokensReached: false)

        let tDec = Date()
        for step in 0..<options.maxTokens {
            if nextToken == Constants.speechStopToken && generated.count >= options.minTokens {
                stoppedNaturally = true
                break
            }
            let writePos = realLength + step
            guard writePos < maxSeq else { break }   // cache full
            generated.append(nextToken)

            updateMask.withUnsafeMutableBytes { raw, _ in
                let um = raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)
                if prevPos >= 0 { um[prevPos] = 0 }
                um[writePos] = 1
            }
            prevPos = writePos
            attnMaskD.withUnsafeMutableBytes { raw, _ in
                let am = raw.baseAddress!.bindMemory(to: Float16.self, capacity: maxSeq)
                am[writePos] = 0                      // unmask the row we're writing
            }
            posArr.withUnsafeMutableBytes { raw, _ in
                raw.baseAddress!.bindMemory(to: Int32.self, capacity: 1)[0] = Int32(writePos)
            }
            let embeds = try MLMultiArray.float16(speechEmb.row(nextToken), shape: [1, 1, hidden])

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "inputs_embeds": embeds,
                "position_ids": posArr,
                "update_mask": updateMask,
                "attn_mask": attnMaskD,
            ])
            let out = try predictTrapping(decodeModel, from: provider, label: "T3LM decode") {
                try $0.prediction(from: $1, using: state, options: MLPredictionOptions())
            }
            guard let logitsArr = out.featureValue(for: "logits")?.multiArrayValue else {
                throw ChatterboxError.invalidModelOutput("T3LM decode missing 'logits'")
            }
            let logits = try logitsArr.toFloatArrayAnyPrecision()
            if step < 4 {
                Self.logTopK(logits, label: "[decode:t3lm] step=\(step) top-5", count: 5)
            }
            nextToken = sampler.sample(
                logits: logits, previous: generated,
                minTokensReached: generated.count >= options.minTokens)
        }
        let decodeTime = Date().timeIntervalSince(tDec)

        Log.decode.debug("[decode:t3lm] generated \(generated.count, privacy: .public) tokens, stoppedNaturally=\(stoppedNaturally, privacy: .public), prefillLen=\(realLength, privacy: .public)")
        let msPerTok = generated.isEmpty ? 0 : decodeTime * 1000 / Double(generated.count)
        Log.decode.debug("[decode:t3lm] decodeTime=\(decodeTime, format: .fixed(precision: 3), privacy: .public)s tokens=\(generated.count, privacy: .public) ms/tok=\(msPerTok, format: .fixed(precision: 2), privacy: .public) prefillTime=\(prefillTime, format: .fixed(precision: 3), privacy: .public)s")
        return Output(
            tokens: generated, prefillLength: realLength,
            prefillTime: prefillTime, decodeTime: decodeTime)
        #else
        _ = (textTokens, conds, options)
        preconditionFailure("T3LMRunner requires arm64 (Apple Silicon)")
        #endif
    }

    /// Read both state buffers and log a per-buffer absolute sum. Zero after a
    /// prefill predict means the prefill function's `write_state` op didn't
    /// land in this MLState — i.e., the two MLModel instances (one per
    /// function) aren't sharing buffers despite using the same `state` handle.
    static func logStateSum(_ state: MLState, label: String) {
        // DEBUG-ONLY: sums the entire 75 M-element KV cache, which forces a full
        // ANE→CPU copy of the state buffers (~150 MB) per call — and it's called
        // before AND after every prefill. That's ~12 s/generation, so it must NOT
        // run in production. Gate behind CHATTERBOX_DEBUG_STATE. (State sharing is
        // already audited; only re-enable when debugging write_state landing.)
        guard ProcessInfo.processInfo.environment["CHATTERBOX_DEBUG_STATE"] != nil else { return }
        #if arch(arm64)
        var keySum: Float = 0
        var valSum: Float = 0
        var keyCount = 0
        var valCount = 0
        state.withMultiArray(for: "keyCache") { arr in
            let n = arr.count
            keyCount = n
            arr.withUnsafeBytes { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                for i in 0..<n { keySum += abs(Float(p[i])) }
            }
        }
        state.withMultiArray(for: "valueCache") { arr in
            let n = arr.count
            valCount = n
            arr.withUnsafeBytes { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: Float16.self)
                for i in 0..<n { valSum += abs(Float(p[i])) }
            }
        }
        Log.decode.debug("\(label, privacy: .public) keyCache |sum|=\(keySum, privacy: .public) (\(keyCount, privacy: .public) elems) valueCache |sum|=\(valSum, privacy: .public) (\(valCount, privacy: .public) elems)")
        #endif
    }

    /// Log the top-K token indices and their raw logit values. Used to diagnose
    /// "model stops too early" — if `stop` (6562) is top-1 with a wide margin
    /// the model itself thinks generation is over; if not, the sampler is at
    /// fault.
    static func logTopK(_ logits: [Float], label: String, count: Int = 5) {
        var idx = Array(0..<logits.count)
        idx.sort { logits[$0] > logits[$1] }
        let top = idx.prefix(count).map { "\($0):\(String(format: "%.2f", logits[$0]))" }.joined(separator: ",")
        let stopLogit = (Constants.speechStopToken < logits.count) ? logits[Constants.speechStopToken] : .nan
        Log.decode.debug("\(label, privacy: .public) [\(top, privacy: .public)] stop(\(Constants.speechStopToken, privacy: .public))=\(String(format: "%.2f", stopLogit), privacy: .public)")
    }

    /// Read the .mlpackage Manifest.json (a small JSON describing the package
    /// model spec). For a freshly-converted T3LM it lists the model file as
    /// `model.mlmodel` and includes its file size. Helps a stale or wrong-type
    /// local copy stand out in the log. Returns a compact summary or `nil`.
    private static func peekManifest(at url: URL) -> String? {
        let fm = FileManager.default
        // `.mlpackage` carries Manifest.json at the root; `.mlmodelc` doesn't.
        let manifestURL = url.appendingPathComponent("Manifest.json")
        if fm.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let kind = json["fileFormatVersion"] as? String ?? "?"
            let itemInfoEntries = (json["itemInfoEntries"] as? [String: Any])?.count ?? 0
            // Size of the weight blob — single biggest tell of "is this the right artifact".
            let weight = url.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
            let weightMB = (((try? fm.attributesOfItem(atPath: weight.path))?[.size] as? Int) ?? 0) / 1_000_000
            return "fileFormatVersion=\(kind) itemEntries=\(itemInfoEntries) weight=\(weightMB)MB"
        }
        // For .mlmodelc, list a few top-level entries so a structural mismatch is visible.
        if let entries = try? fm.contentsOfDirectory(atPath: url.path) {
            let preview = entries.sorted().prefix(8).joined(separator: ",")
            return "mlmodelc entries=[\(preview)]"
        }
        return nil
    }

    // MARK: - host-built masks

    /// (1, 1, W, W) fp16. Per (i, j): causal_neg if j > i, plus pad_neg if j ≥
    /// realLength, with the diagonal zeroed so a fully-padded query row never
    /// softmaxes to NaN. Consumed by the prefill function's manual-SDPA add.
    ///
    /// Built here rather than in the graph **on purpose**: constructing this mask
    /// inside the 24-layer stateful prefill makes the ANE compile fail
    /// (`std::bad_cast`, error -14), so the model takes it as a plain input. Folding
    /// it back into the model looks like a simplification and costs ANE placement.
    private func buildPrefillAttnMask(realLength: Int) throws -> MLMultiArray {
        #if arch(arm64)
        let W = maxLen
        let arr = try MLMultiArray(
            shape: [1, 1, NSNumber(value: W), NSNumber(value: W)], dataType: .float16)
        arr.withUnsafeMutableBytes { raw, _ in
            let p = raw.baseAddress!.bindMemory(to: Float16.self, capacity: W * W)
            let zero: Float16 = 0
            for i in 0..<W {
                let rowBase = i * W
                for j in 0..<W {
                    if i == j { p[rowBase + j] = zero; continue }
                    var v: Float = 0
                    if j > i { v += Self.maskNeg }
                    if j >= realLength { v += Self.maskNeg }
                    p[rowBase + j] = Float16(v)
                }
            }
        }
        return arr
        #else
        preconditionFailure("T3LMRunner requires arm64 (Apple Silicon)")
        #endif
    }

    /// (W, 1) fp16: 1.0 for real rows [0..realLength-1], 0.0 for pad rows.
    /// Used in-graph to zero pad K/V before they enter the shared cache so the
    /// decode-side attention over the full MAX_SEQ window reads only real K/V.
    /// Host-built for the same reason as ``buildPrefillAttnMask(realLength:)``.
    private func buildWriteMask(realLength: Int) throws -> MLMultiArray {
        #if arch(arm64)
        let W = maxLen
        let arr = try MLMultiArray(shape: [NSNumber(value: W), 1], dataType: .float16)
        arr.withUnsafeMutableBytes { raw, _ in
            let p = raw.baseAddress!.bindMemory(to: Float16.self, capacity: W)
            for i in 0..<W { p[i] = i < realLength ? Float16(1.0) : Float16(0.0) }
        }
        return arr
        #else
        preconditionFailure("T3LMRunner requires arm64 (Apple Silicon)")
        #endif
    }
}
