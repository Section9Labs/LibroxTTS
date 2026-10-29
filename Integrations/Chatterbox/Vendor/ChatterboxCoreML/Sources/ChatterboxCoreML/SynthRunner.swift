import CoreML
import Foundation

/// Optional per-stage compute-units override for the whole CoreML pipeline — the
/// multifunction T3LM (prefill+decode) plus the three synth models (encoder / CFM /
/// vocoder) — threaded from the app's model-load entry point
/// (``ChatterboxCoreMLModel/load``) into ``T3LMRunner``/``MTLT3LMRunner`` and
/// ``SynthRunner``. Each `nil` field defers to the stage's existing resolution (the
/// `CHATTERBOX_DECODE_CU` / `CHATTERBOX_SYNTH_*_CU` env var, then its built-in
/// default); a non-nil field wins over both. This is the runtime-toggle path:
/// `ProcessInfo.processInfo` snapshots the env at first access, so a `setenv` after
/// launch is unreliable — the app forces placement through this struct instead.
/// Default `.init()` (all nil) = zero behavior change for the CLI, tests, and
/// existing callers.
public struct PipelineComputeUnits: Sendable {
    public var t3: MLComputeUnits?
    public var encoder: MLComputeUnits?
    public var cfm: MLComputeUnits?
    public var vocoder: MLComputeUnits?
    /// The Perth watermark encoder (`perth-coreml`). Proven ANE-resident under
    /// `.all` on device, so it needs no special handling in the background case —
    /// it is here only so ``neuralEngine`` can pin the *whole* pipeline.
    public var watermark: MLComputeUnits?
    public init(t3: MLComputeUnits? = nil, encoder: MLComputeUnits? = nil,
                cfm: MLComputeUnits? = nil, vocoder: MLComputeUnits? = nil,
                watermark: MLComputeUnits? = nil) {
        self.t3 = t3
        self.encoder = encoder
        self.cfm = cfm
        self.vocoder = vocoder
        self.watermark = watermark
    }

    /// Whole pipeline forced onto the Neural Engine (`cpuAndNeuralEngine`): the
    /// background-capable path (iPhone has no background GPU — any GPU submission
    /// from a backgrounded app fails with "Insufficient Permissions to submit GPU
    /// work from background"). Among the synth stages only the CFM genuinely executes
    /// on the ANE (its padded-ANE mode engages automatically via `usesANE`); the
    /// vocoder executes on CPU under this CU at its shapes (its ANE "prepare and
    /// cache" is a one-time cost, E5-cached after). The encoder is the exception: it
    /// stays on ``SynthRunner/encoderDefault`` (CPU), which is background-safe too —
    /// see there for why it must not be placed on the ANE. T3LM prefill/decode
    /// are already ANE-resident under the `.all` default — forcing
    /// `t3 = .cpuAndNeuralEngine` moves their small non-ANE segments off the GPU and
    /// onto the CPU (a device trace showed a per-decode-step GPU Request under `.all`,
    /// which is what breaks background execution).
    public static let neuralEngine = PipelineComputeUnits(
        t3: .cpuAndNeuralEngine, encoder: SynthRunner.encoderDefault,
        cfm: .cpuAndNeuralEngine, vocoder: .cpuAndNeuralEngine,
        watermark: .cpuAndNeuralEngine)
}

/// CoreML audio synthesis: the S3Gen flow split into three CoreML packages,
/// orchestrated in Swift, with the glue between them done here:
///
///   1. **S3Encoder**  speech_tokens (1,T) i32 → mu (1,80,T_h=2T)   [ANE]
///   2. build conditioning (cond/mask/z) the way `flow.inference` does
///   3. **S3CFM** Euler loop — auto-detected from the CFM graph:
///      · turbo  meanflow: 2 steps, one predict (x,mu,cond,spks_raw,t,r,mask)→velocity.
///      · multilingual CFG: 10 cosine steps, TWO predicts/step (cond + uncond via
///        `spks_scale`), dxdt=(1+0.7)·v_cond−0.7·v_uncond.                [cpuAndGPU]
///   4. slice off the prompt frames (feat = x[:, :, mel_len1:])
///   5. **S3Vocoder**  feat (1,80,T_gen) → waveform (1, T_gen*480)    [cpuAndGPU]
///
/// Device-measured warm latencies (iPhone 17 Pro Max, iOS 26.5, 2026-05-29):
/// encoder ~95 ms, CFM ~98 ms/step, vocoder ~48 ms (GPU, cos 0.998) / ~472 ms
/// (cpuOnly, cos 0.99998) → ~0.24–0.76 s/utterance.
///
/// **CU pins (important):** S3CFM defaults to `cpuAndGPU` (foreground). The old
/// bnns-AOT load crash on cpuOnly/ane/all was fixed in the converter (spks broadcast
/// derived from x's own symbol), so the ANE is now a valid CFM target — but the
/// exported package is flexible-shape (RangeDim [1,2048]) and the ANE executes it only
/// at the **default shape 1024**. So when the CFM CU includes the Neural Engine the
/// runner switches to the *padded-ANE mode*: right-pad T_h≤1024 up to 1024 and run the
/// whole Euler/CFG loop there (pad frames made inert by the graph's in-graph mask
/// attention-bias), slicing the real frames back before the vocoder. Encoder is ~95 ms
/// warm on either ANE or cpuOnly. Vocoder is the only quality/speed knob: cpuOnly
/// (clean) vs cpuAndGPU (fast, fp16-ISTFT 0.998). Override per stage with
/// `CHATTERBOX_SYNTH_{ENC,CFM,VOC}_CU` (cpu|gpu|ane|all), or with a
/// ``PipelineComputeUnits`` passed to `init` (an explicit non-nil field wins over the
/// env var — the app uses it to force the ANE path without relying on the cached
/// `ProcessInfo` env snapshot). `CHATTERBOX_CFM_STEPS` sets the Euler step count
/// (default 10 multilingual / 2 turbo); `CHATTERBOX_SYNTH_CFM_PAD=1` forces the
/// padded path on any CU (test hook — see `synthesizeWindow`).
///
/// **`@unchecked Sendable`** (matches the `T3LMRunner`/`MTLT3LMRunner` convention):
/// every stored property is an immutable `let` (the three `MLModel`s, `cfmSteps`,
/// `cfgMode`, `cfgRate`, `mel`) and `synthesize` keeps **no** cross-call mutable
/// state — every scratch buffer is a local in `synthesizeWindow`. `MLModel` is
/// itself safe for concurrent `prediction(from:)`. The chunk pipeline (issue #22)
/// drives it from a single dedicated synth task that is never re-entered
/// concurrently, so off-actor use is race-free. (`cfmUsesANE` is the one property
/// added since — still an immutable `let`, so the guarantee holds.)
final class SynthRunner: @unchecked Sendable {
    /// Where the S3Encoder runs unless the caller or `CHATTERBOX_SYNTH_ENC_CU` says otherwise:
    /// the CPU, in the foreground AND in ``PipelineComputeUnits/neuralEngine``.
    ///
    /// On iOS 27 the encoder's flexible-length (`RangeDim`) graph on the Neural Engine takes the
    /// process from ~0.7 GB to 2.3–3.5 GB; under that memory pressure the host app segfaulted
    /// inside CoreML after the first long chunk (device-measured, iPhone 17 Pro Max, 2026-09-26).
    /// On the CPU it stays at 0.7–1.2 GB and is also faster (0.07–0.48 s vs 0.55–0.8 s per chunk).
    /// The CPU is not background-restricted, so the locked-phone placement keeps working.
    static let encoderDefault: MLComputeUnits = .cpuOnly

    private let encoder: MLModel
    private let cfm: MLModel
    private let vocoder: MLModel
    private let cfmSteps: Int
    private let reuseFlowInputs: Bool
    /// Per-load evaluation override. Nil retains the upstream environment policy.
    private let padFlowToMaximum: Bool?
    private let mel = Constants.melBins   // 80

    /// Whether the resolved CFM compute units include the Neural Engine
    /// (`cpuAndNeuralEngine`/`all`). Gates the padded-ANE execution mode: the ANE
    /// runs the flexible-shape S3CFM only at its RangeDim default shape (1024), so
    /// when it's in play the runner right-pads T_h≤1024 up to `cfmPadTarget` and runs
    /// the whole Euler/CFG loop there. False (the `cpuAndGPU` default) → unpadded,
    /// byte-identical to the pre-padding behavior.
    private let cfmUsesANE: Bool

    /// Multilingual non-meanflow CFM: detected when the S3CFM graph exposes the
    /// `spks_scale` input (turbo's meanflow CFM has `r` instead). Drives a 10-step
    /// **cosine-schedule, classifier-free-guidance** Euler loop (two estimator
    /// predicts/step) vs turbo's 2-step meanflow loop (one predict/step, no CFG).
    private let cfgMode: Bool
    /// Flow CFG strength = s3gen `inference_cfg_rate` (fixed model constant, NOT the
    /// T3 token `cfg_weight`): dxdt = (1+r)·v_cond − r·v_uncond.
    private let cfgRate: Float = 0.7

    /// Loads the three synth models, each on its pinned compute unit. `computeUnits`
    /// carries optional per-stage overrides: a non-nil field wins over the stage's
    /// `CHATTERBOX_SYNTH_*_CU` env var and its built-in default. Default `.init()`
    /// (all nil) = unchanged behavior (env, then default).
    init(encoderURL: URL, cfmURL: URL, vocoderURL: URL,
         computeUnits: PipelineComputeUnits = .init(),
         padFlowToMaximum: Bool? = nil, reuseFlowInputs: Bool = false) throws {
        self.padFlowToMaximum = padFlowToMaximum
        self.reuseFlowInputs = reuseFlowInputs
        func cu(_ envKey: String, _ override: MLComputeUnits?, default def: MLComputeUnits) -> MLComputeUnits {
            if let override { return override }   // explicit app override wins over env + default
            switch ProcessInfo.processInfo.environment[envKey]?.lowercased() {
            case "cpu", "cpuonly": return .cpuOnly
            case "gpu", "cpuandgpu": return .cpuAndGPU
            case "ane", "ne", "cpuandne": return .cpuAndNeuralEngine
            case "all": return .all
            default: return def
            }
        }
        func load(_ url: URL, _ units: MLComputeUnits, _ label: String) throws -> MLModel {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units
            let t = Date()
            do {
                let m = try MLModel(contentsOf: url, configuration: cfg)
                Log.load.notice("[load:synth] \(label, privacy: .public) loaded cu=\(String(describing: units), privacy: .public) \(Date().timeIntervalSince(t), format: .fixed(precision: 2), privacy: .public)s")
                return m
            } catch {
                Log.load.error("[load:synth] \(label, privacy: .public) FAILED at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        // Encoder → CPU (see `encoderDefault`).
        encoder = try load(encoderURL, cu("CHATTERBOX_SYNTH_ENC_CU", computeUnits.encoder, default: Self.encoderDefault), "S3Encoder")
        // CFM → cpuAndGPU by default (foreground). The converter's spks-broadcast fix
        // means every CU now loads clean; including the ANE flips on the padded mode.
        let cfmCU = cu("CHATTERBOX_SYNTH_CFM_CU", computeUnits.cfm, default: .cpuAndGPU)
        cfm = try load(cfmURL, cfmCU, "S3CFM")
        cfmUsesANE = (cfmCU == .cpuAndNeuralEngine || cfmCU == .all)
        // Vocoder → cpuAndGPU (~48 ms warm). The fp16-ISTFT there is cos 0.998 vs
        // 0.99998 on cpuOnly (~472 ms), a ~3.5% RMS waveform difference judged
        // inaudible in a seed-locked A/B (2026-05-29). Set CHATTERBOX_SYNTH_VOC_CU=cpu
        // for the cleaner-but-10×-slower path.
        vocoder = try load(vocoderURL, cu("CHATTERBOX_SYNTH_VOC_CU", computeUnits.vocoder, default: .cpuAndGPU), "S3Vocoder")

        // Multilingual non-meanflow CFM exposes `spks_scale`; turbo meanflow has `r`.
        let isCfg = cfm.modelDescription.inputDescriptionsByName["spks_scale"] != nil
        cfgMode = isCfg
        // Multilingual flow uses 10 cosine CFG steps; turbo meanflow uses 2.
        let defaultSteps = isCfg ? 10 : 2
        let steps = Int(ProcessInfo.processInfo.environment["CHATTERBOX_CFM_STEPS"] ?? "") ?? defaultSteps
        let nSteps = max(1, steps)
        cfmSteps = nSteps
        Log.load.notice("[load:synth] S3CFM mode=\(isCfg ? "multilingual-CFG" : "turbo-meanflow", privacy: .public) steps=\(nSteps, privacy: .public)")
    }

    /// Synthesizes a 24 kHz waveform for `generatedTokens` under voice `conds`.
    /// API-compatible with the retired `ConditionalDecoderRunner`.
    ///
    /// The S3Encoder caps `speech_tokens` (= `prompt ++ generated`) at
    /// `Constants.maxVocoderTokens` (1020 — four under the graph's own 1024 bound,
    /// which fails on the ANE/GPU). A long chunk can blow past that, so the
    /// generated tokens are split into windows that each fit alongside the prompt;
    /// the prompt is re-prepended to (and its mel frames sliced off) every window,
    /// so concatenating the per-window waveforms reconstructs the full audio with
    /// consistent voice conditioning. Short chunks (the common path) take a single
    /// window and are byte-for-byte unchanged. In padded-ANE mode the window is
    /// capped tighter still (`windowBudget`) so every window's T_h ≤ `cfmPadTarget`
    /// and the CFM actually pads onto the Neural Engine per window.
    func synthesize(generatedTokens: [Int], conds: Conditionals) throws -> [Float] {
        try synthesizeMeasured(generatedTokens: generatedTokens, conds: conds).samples
    }

    func synthesizeMeasured(generatedTokens: [Int], conds: Conditionals) throws -> ChatterboxAcousticOutput {
        try Task.checkCancellation()
        // Clamp to the decoder's valid speech-token range up front.
        let validGenerated = generatedTokens
            .filter { $0 >= 0 && $0 <= Constants.speechTokenMaxValid }
            .map { Int32($0) }

        // Match `synthesizeWindow`'s pad gate so the window cap and the per-window
        // pad decision agree: when padding is in play each window must additionally
        // fit T_h ≤ cfmPadTarget, or it drops off the ANE to a CPU fallback.
        let forcePad = padFlowToMaximum ?? (ProcessInfo.processInfo.environment["CHATTERBOX_SYNTH_CFM_PAD"] == "1")
        let windowSize = Self.windowBudget(
            promptTokens: conds.promptTokens.count, pad: cfmUsesANE || forcePad)
        let windows = Self.tokenWindows(validGenerated, maxPerWindow: windowSize)
        guard windows.count > 1 else {
            return try synthesizeWindow(validGenerated, conds: conds)
        }
        Log.pipeline.debug("[synth] generated \(validGenerated.count, privacy: .public) > vocoder window \(windowSize, privacy: .public) (prompt \(conds.promptTokens.count, privacy: .public)) → \(windows.count, privacy: .public) windows")
        var waveform: [Float] = []
        var timings = ChatterboxAcousticTimings()
        timings.promptTokens = conds.promptTokens.count
        for window in windows {
            try Task.checkCancellation()
            let output = try synthesizeWindow(window, conds: conds)
            waveform.append(contentsOf: output.samples)
            timings.encoderSeconds += output.timings.encoderSeconds
            timings.preparationSeconds += output.timings.preparationSeconds
            timings.flowSeconds += output.timings.flowSeconds
            timings.vocoderSeconds += output.timings.vocoderSeconds
            timings.generatedTokens += output.timings.generatedTokens
            timings.windows += output.timings.windows
            timings.flowPredictions += output.timings.flowPredictions
        }
        timings.reusedFlowInputBuffers = reuseFlowInputs
        return .init(samples: waveform, timings: timings)
    }

    /// Splits `tokens` into in-order windows of at most `maxPerWindow` each, with
    /// no token dropped or duplicated. Returns a single (possibly empty) window
    /// when `tokens` already fits, so callers can treat the one-window case as the
    /// unchanged single pass. Pure — unit-tested without the CoreML models.
    static func tokenWindows(_ tokens: [Int32], maxPerWindow: Int) -> [[Int32]] {
        let stride = max(1, maxPerWindow)
        guard tokens.count > stride else { return [tokens] }
        var windows: [[Int32]] = []
        var i = 0
        while i < tokens.count {
            windows.append(Array(tokens[i..<min(i + stride, tokens.count)]))
            i += stride
        }
        return windows
    }

    /// Per-window generated-token budget. The S3Encoder caps `prompt ++ generated`
    /// at `Constants.maxVocoderTokens`, so the base budget is `maxVocoderTokens −
    /// prompt`. In padded-ANE mode (`pad` = `cfmUsesANE || CHATTERBOX_SYNTH_CFM_PAD`,
    /// the same gate as `shouldPad`) the CFM only runs on the Neural Engine when it
    /// pads to `cfmPadTarget`, which needs T_h = 2·(prompt+gen) ≤ cfmPadTarget — so
    /// each window is additionally capped to `cfmPadTarget/2 − prompt`. Without this
    /// a real utterance (turbo prompt 250 + ≥263 gen → T_h > 1024) exceeds the pad
    /// target, runs unpadded at a non-default RangeDim shape, and falls back to CPU
    /// (~3× the ANE latency). Forcing the pad in tests caps windows the same way so
    /// the forced path splits identically. Degenerate guard: a prompt ≥
    /// cfmPadTarget/2 (huge cloned voice) makes that cap ≤0, so we keep the unpadded
    /// encoder budget (CPU fallback) rather than emit absurd 1-token windows. Pure.
    static func windowBudget(promptTokens: Int, pad: Bool) -> Int {
        let encoderCap = Constants.maxVocoderTokens - promptTokens
        guard pad else { return max(1, encoderCap) }
        let aneCap = cfmPadTarget / 2 - promptTokens
        guard aneCap > 0 else { return max(1, encoderCap) }   // huge prompt → no ANE cap
        return max(1, min(encoderCap, aneCap))
    }

    /// Tokens to append so the encoder's `speech_tokens` length is a multiple of 4
    /// (the graph is only numerically correct there — see `synthesizeWindow` step 2).
    /// Pure, and shared with the tests that assert a padded window can never land on
    /// `Constants.encoderTokenLimit`.
    static func encoderPad(_ count: Int) -> Int { (4 - count % 4) % 4 }

    // MARK: - Padded-ANE CFM plumbing

    /// Right-pad target for the CFM latent's T (frame) axis when running on the ANE.
    /// **1024 is the ONLY shape the exported S3CFM executes on the Neural Engine:** the
    /// package is RangeDim [1,2048] with default shape 1024, and a flexible-shape
    /// mlprogram runs on the ANE only at its default shape (coremltools #2370). Other
    /// shapes fall back to CPU/GPU. So T_h≤1024 is padded up to exactly this; T_h>1024
    /// can't and runs unpadded (CPU/GPU).
    static let cfmPadTarget = 1024

    /// Whether to run the CFM Euler/CFG loop at the padded ANE shape (`cfmPadTarget`):
    /// the resolved CFM compute units include the Neural Engine, OR the
    /// `CHATTERBOX_SYNTH_CFM_PAD` test override forces it — AND the real mel length fits
    /// the pad target. False (the `cpuAndGPU` default) → unpadded, unchanged. Pure.
    static func shouldPad(usesANE: Bool, forcePad: Bool, tH: Int) -> Bool {
        (usesANE || forcePad) && tH <= cfmPadTarget
    }

    /// Right-pad the T (frame) axis of a `(mel, srcT)` C-order plane to `(mel, dstT)`,
    /// zero-filling the appended columns. Identity copy when `dstT == srcT`. The pad is
    /// on the RIGHT so real frames keep their column index (the prompt-frame slice still
    /// drops from the LEFT). Pure — unit-tested without a model.
    static func padFrames(_ src: [Float], mel: Int, srcT: Int, dstT: Int) -> [Float] {
        precondition(dstT >= srcT && src.count == mel * srcT)
        if dstT == srcT { return src }
        var out = [Float](repeating: 0, count: mel * dstT)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for m in 0..<mel {
                    let so = m * srcT, dof = m * dstT
                    for f in 0..<srcT { d[dof + f] = s[so + f] }
                }
            }
        }
        return out
    }

    /// CFM `mask` of length `runT`: 1 for the first `realT` frames, 0 for the RIGHT pad.
    /// All-ones when `runT == realT`. The graph turns a 0 into a −1e4 key-side attention
    /// bias, so padded frames are numerically inert. Pure.
    static func padMask(realT: Int, runT: Int) -> [Float] {
        var m = [Float](repeating: 0, count: runT)
        for f in 0..<min(realT, runT) { m[f] = 1 }
        return m
    }

    /// Slice `x[:, :, start ..< start+count]` from a `(mel, runT)` C-order plane →
    /// `(mel, count)`. Drops the LEFT `start` prompt frames and any RIGHT pad past
    /// `start+count`. Pure — unit-tested without a model.
    static func sliceFrames(_ x: [Float], mel: Int, runT: Int, start: Int, count: Int) -> [Float] {
        precondition(start + count <= runT && x.count == mel * runT)
        var feat = [Float](repeating: 0, count: mel * count)
        x.withUnsafeBufferPointer { xb in
            for m in 0..<mel {
                let src = m * runT + start
                let dst = m * count
                for k in 0..<count { feat[dst + k] = xb[src + k] }
            }
        }
        return feat
    }

    /// Runs the three-package synth for one window's worth of `generated` speech
    /// tokens (already clamped to the valid range), prepended with the voice
    /// prompt. The prompt's mel frames are sliced off before vocoding.
    private func synthesizeWindow(_ generated: [Int32], conds: Conditionals) throws -> ChatterboxAcousticOutput {
        try Task.checkCancellation()
        // 1. all_tokens = prompt ++ generated.
        let allTokens = conds.promptTokens + generated
        guard !allTokens.isEmpty else {
            throw ChatterboxError.invalidModelOutput("no speech tokens to synthesize")
        }

        // 2. Encoder: speech_tokens (1,T) → mu (1,80,T_h=2T).  mu output is fp16.
        //    The UpsampleConformerEncoder's CoreML graph is only correct when the
        //    token count is a multiple of 4 (RangeDim dynamic-shape quirk: T%4==0 →
        //    mu cos 0.99998, else ~0.97 — isolated 2026-06-19, shared with the turbo
        //    encoder arch). Pad the input up to a multiple of 4 (repeat the last
        //    token) and trim the extra 2·pad output frames; the small bidirectional
        //    contamination from the pad keeps mu ≥0.994 (vs 0.97 unpadded). A clean
        //    converter-side fix is a follow-up (issue #17).
        let tEnc = Date()
        let realT = allTokens.count
        let pad = Self.encoderPad(realT)
        let encTokens = pad == 0 ? allTokens
            : allTokens + Array(repeating: allTokens.last ?? 0, count: pad)
        // A window that reaches `encoderTokenLimit` (1024, the RangeDim default
        // shape) kills the app: the ANE raises an ObjC `NSGenericException` out of
        // `prediction(from:)` that Swift cannot catch (see `Constants
        // .maxVocoderTokens`). `windowBudget` keeps every window ≤ 1020, so this can
        // only trip on a degenerate prompt (one at/over the cap by itself) — fail the
        // utterance with a real Swift error instead of terminating the process.
        guard encTokens.count < Constants.encoderTokenLimit else {
            throw ChatterboxError.invalidModelOutput(
                "encoder input \(encTokens.count) tokens (prompt \(conds.promptTokens.count) + "
                + "generated \(generated.count)) reaches the S3Encoder default shape "
                + "\(Constants.encoderTokenLimit), which fails on the ANE/GPU")
        }
        let muArr = try predict(encoder,
                                inputs: ["speech_tokens": MLMultiArray.int32(encTokens, shape: [1, encTokens.count])],
                                output: "mu")
        let muShape = muArr.shape.map { $0.intValue }
        guard muShape.count == 3, muShape[1] == mel else {
            throw ChatterboxError.invalidModelOutput("encoder mu shape \(muShape) != (1,80,T_h)")
        }
        let tEncOut = muShape[2]                 // 2·encTokens.count
        let tH = 2 * realT                       // trim the padded frames off
        var mu = try muArr.toFloatArrayAnyPrecision()
        if pad != 0 {
            var trimmed = [Float](repeating: 0, count: mel * tH)
            mu.withUnsafeBufferPointer { m in
                for c in 0..<mel {
                    let src = c * tEncOut, dst = c * tH
                    for f in 0..<tH { trimmed[dst + f] = m[src + f] }
                }
            }
            mu = trimmed
        }

        let encoderEnd = Date()
        // 3. Conditioning, mirroring flow.inference:
        //    mel_len1 = #prompt mel frames; cond = prompt_feat in the first mel_len1
        //    frames, zero elsewhere; spks = L2-normed xvec. `mask` marks the real
        //    frames (all-ones unpadded; 1s-then-0s in padded-ANE mode).
        let melLen1 = conds.promptFeat.count / mel
        guard melLen1 > 0, melLen1 < tH else {
            throw ChatterboxError.invalidModelOutput("prompt frames \(melLen1) not in (0, T_h=\(tH))")
        }
        let melLen2 = tH - melLen1

        // Padded-ANE mode: when the CFM CU includes the Neural Engine (or the
        // CHATTERBOX_SYNTH_CFM_PAD test override) AND T_h≤1024, run the whole Euler
        // loop at the RangeDim default shape 1024 (`cfmPadTarget`) — the only shape the
        // ANE executes. All T-carrying inputs are right-padded with zeros; the graph's
        // in-graph mask attention-bias makes the pad frames numerically inert, so the
        // sliced real frames match the unpadded run (≥0.99999). Otherwise tRun == T_h
        // and everything below is byte-identical to the pre-padding path. The env hook
        // lets the padded path be exercised on any CU (e.g. Mac cpuAndGPU) for tests.
        let forcePad = padFlowToMaximum ?? (ProcessInfo.processInfo.environment["CHATTERBOX_SYNTH_CFM_PAD"] == "1")
        let padded = Self.shouldPad(usesANE: cfmUsesANE, forcePad: forcePad, tH: tH)
        let tRun = padded ? Self.cfmPadTarget : tH

        // cond (1,80,tRun) C-order: cond[m, f] = prompt_feat[f, m] for f<melLen1 else 0
        // (pad columns f≥T_h stay zero). prompt_feat is (frames,80) C-order.
        var cond = [Float](repeating: 0, count: mel * tRun)
        conds.promptFeat.withUnsafeBufferPointer { pf in
            for f in 0..<melLen1 {
                let base = f * mel
                for m in 0..<mel { cond[m * tRun + f] = pf[base + m] }
            }
        }

        let mask = Self.padMask(realT: tH, runT: tRun)                     // (1,1,tRun)
        let spks = conds.normalizedSpeakerEmbedding                        // (1,192)
        guard spks.count == Constants.camppEmbDim else {
            throw ChatterboxError.invalidModelOutput("speaker emb dim \(spks.count) != \(Constants.camppEmbDim)")
        }

        let condArr = try MLMultiArray.float32(cond, shape: [1, mel, tRun])
        let maskArr = try MLMultiArray.float32(mask, shape: [1, 1, tRun])
        let spksArr = try MLMultiArray.float32(spks, shape: [1, spks.count])
        let muInArr = try MLMultiArray.float32(
            Self.padFrames(mu, mel: mel, srcT: tH, dstT: tRun), shape: [1, mel, tRun])

        // 4. CFM Euler loop. z = randn(1,80,T_h).
        //    · Multilingual (cfgMode): cosine t_span = 1−cos(s·π/2), s = i/n; each step
        //      runs TWO predicts — conditional (real mu/cond, spks_scale=1) and
        //      unconditional (zeroed mu/cond, spks_scale=0) — and combines
        //      dxdt = (1+cfgRate)·v_cond − cfgRate·v_uncond; x += (r−t)·dxdt.
        //    · Turbo meanflow: linear t_span, one predict v=estimator(…,t,r); x += (r−t)·v.
        //    In padded-ANE mode z/x carry real noise in the first T_h frames and zeros
        //    in the pad (the pad is inert, so its content is irrelevant — zeros keep it
        //    clean); the same seed reproduces the unpadded real-region noise exactly.
        var x = Self.padFrames(randn(count: mel * tH), mel: mel, srcT: tH, dstT: tRun)
        let tCFM = Date()
        let n = cfmSteps
        let zeroMelArr = try MLMultiArray.float32([Float](repeating: 0, count: mel * tRun), shape: [1, mel, tRun])
        let scale1 = try MLMultiArray.float32([1], shape: [1])
        let scale0 = try MLMultiArray.float32([0], shape: [1])
        // These inputs are owned by this invocation and used only by synchronous
        // predictions. Outputs have been read before either buffer is overwritten.
        let reusableX = reuseFlowInputs ? try MLMultiArray.float32(x, shape: [1, mel, tRun]) : nil
        let reusableT = reuseFlowInputs ? try MLMultiArray.float32([0], shape: [1]) : nil
        func tSpan(_ s: Float) -> Float { cfgMode ? (1 - Foundation.cos(s * 0.5 * .pi)) : s }
        for i in 0..<n {
            try Task.checkCancellation()
            let t = tSpan(Float(i) / Float(n))
            let r = tSpan(Float(i + 1) / Float(n))
            let dt = r - t
            let xArr: MLMultiArray, tArr: MLMultiArray
            if let reusableX, let reusableT {
                try reusableX.replaceContiguousFloat32(with: x)
                try reusableT.replaceContiguousFloat32(with: [t])
                xArr = reusableX; tArr = reusableT
            } else {
                xArr = try MLMultiArray.float32(x, shape: [1, mel, tRun])
                tArr = try MLMultiArray.float32([t], shape: [1])
            }
            let dxdt: [Float]
            if cfgMode {
                let conditionalInputs: [String: MLMultiArray] = [
                    "x": xArr, "mu": muInArr, "cond": condArr, "spks_raw": spksArr,
                    "t": tArr, "mask": maskArr, "spks_scale": scale1,
                ]
                if i == 0 { try dumpFirstCFMInputsIfRequested(conditionalInputs) }
                let vc = try predict(cfm, inputs: conditionalInputs, output: "velocity").toFloatArrayAnyPrecision()
                try Task.checkCancellation()
                let vu = try predict(cfm, inputs: [
                    "x": xArr, "mu": zeroMelArr, "cond": zeroMelArr, "spks_raw": spksArr,
                    "t": tArr, "mask": maskArr, "spks_scale": scale0,
                ], output: "velocity").toFloatArrayAnyPrecision()
                guard vc.count == x.count, vu.count == x.count else {
                    throw ChatterboxError.invalidModelOutput("CFM velocity count \(vc.count)/\(vu.count) != \(x.count)")
                }
                dxdt = zip(vc, vu).map { (1 + cfgRate) * $0 - cfgRate * $1 }
            } else {
                let v = try predict(cfm, inputs: [
                    "x": xArr, "mu": muInArr, "cond": condArr, "spks_raw": spksArr,
                    "t": tArr, "r": MLMultiArray.float32([r], shape: [1]), "mask": maskArr,
                ], output: "velocity").toFloatArrayAnyPrecision()
                guard v.count == x.count else {
                    throw ChatterboxError.invalidModelOutput("CFM velocity count \(v.count) != \(x.count)")
                }
                dxdt = v
            }
            for j in 0..<x.count { x[j] += dt * dxdt[j] }
        }

        // 5. Slice off the prompt frames (LEFT) and any ANE pad (RIGHT): feat =
        //    x[:, :, melLen1 ..< melLen1+melLen2] over the run stride → (1,80,melLen2).
        let feat = Self.sliceFrames(x, mel: mel, runT: tRun, start: melLen1, count: melLen2)

        // 6. Vocoder: feat (1,80,melLen2) → waveform (1, melLen2*480). trim_fade is
        //    applied inside the model graph (S3VocoderWrapper).
        let tVoc = Date()
        try Task.checkCancellation()
        let wavArr = try predict(vocoder,
                                 inputs: ["feat": MLMultiArray.float32(feat, shape: [1, mel, melLen2])],
                                 output: "waveform")
        let waveform = try wavArr.toFloatArrayAnyPrecision()

        Log.pipeline.debug("[synth] T_tok=\(allTokens.count, privacy: .public) T_h=\(tH, privacy: .public) T_run=\(tRun, privacy: .public) pad=\(padded, privacy: .public) gen=\(melLen2, privacy: .public) steps=\(n, privacy: .public) · enc \(tCFM.timeIntervalSince(tEnc), format: .fixed(precision: 3), privacy: .public)s cfm \(tVoc.timeIntervalSince(tCFM), format: .fixed(precision: 3), privacy: .public)s voc \(Date().timeIntervalSince(tVoc), format: .fixed(precision: 3), privacy: .public)s → \(waveform.count, privacy: .public) samples")
        var timings = ChatterboxAcousticTimings()
        timings.encoderSeconds = encoderEnd.timeIntervalSince(tEnc)
        timings.preparationSeconds = tCFM.timeIntervalSince(encoderEnd)
        timings.flowSeconds = tVoc.timeIntervalSince(tCFM)
        timings.vocoderSeconds = Date().timeIntervalSince(tVoc)
        timings.promptTokens = conds.promptTokens.count
        timings.generatedTokens = generated.count
        timings.windows = 1
        timings.flowPredictions = n * (cfgMode ? 2 : 1)
        timings.reusedFlowInputBuffers = reuseFlowInputs
        return .init(samples: waveform, timings: timings)
    }

    /// Explicit diagnostic capture for a consented local probe. Absent the env
    /// setting this is a no-op; an existing directory is never overwritten.
    /// The manifest is published last, so a partial capture is recognizable.
    private func dumpFirstCFMInputsIfRequested(_ inputs: [String: MLMultiArray]) throws {
        guard let path = ProcessInfo.processInfo.environment["CHATTERBOX_DUMP_CFM_INPUTS"],
              path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [String: Any] = [:]
        for name in inputs.keys.sorted() {
            guard let array = inputs[name] else { continue }
            let values = try array.toFloatArrayAnyPrecision()
            let data = values.withUnsafeBytes { Data($0) }
            let filename = name + ".float32le"
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            records[name] = ["shape": array.shape.map(\.intValue),
                "originalStrides": array.strides.map(\.intValue),
                "originalDataType": array.dataType.rawValue,
                "storage": "float32-little-endian-C-order", "file": filename,
                "finite": values.allSatisfy(\.isFinite)]
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "stage": "S3CFM-first-conditional-step",
            "requestedComputeUnits": String(describing: cfm.configuration.computeUnits), "inputs": records]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// One synchronous CoreML predict, returning the named output's MLMultiArray.
    private func predict(_ model: MLModel, inputs: [String: MLMultiArray], output: String) throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(
            dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        let out = try predictTrapping(model, from: provider, label: "synth[\(output)]")
        guard let arr = out.featureValue(for: output)?.multiArrayValue else {
            throw ChatterboxError.invalidModelOutput("synth model missing output '\(output)'")
        }
        return arr
    }

    /// Standard-normal noise (Box–Muller). Deterministic when `CHATTERBOX_SYNTH_SEED`
    /// is set (reproducible tests); otherwise system entropy. TTS is inherently
    /// stochastic, so a different draw than PyTorch is expected and fine.
    private func randn(count: Int) -> [Float] {
        var gen: any RandomNumberGenerator
        if let s = ProcessInfo.processInfo.environment["CHATTERBOX_SYNTH_SEED"], let seed = UInt64(s) {
            gen = SplitMix64(seed: seed)
        } else {
            gen = SystemRandomNumberGenerator()
        }
        var out = [Float](repeating: 0, count: count)
        var i = 0
        while i < count {
            let u1 = max(Float.random(in: 0..<1, using: &gen), 1e-7)
            let u2 = Float.random(in: 0..<1, using: &gen)
            let radius = (-2 * Foundation.log(u1)).squareRoot()
            out[i] = radius * Foundation.cos(2 * .pi * u2)
            if i + 1 < count { out[i + 1] = radius * Foundation.sin(2 * .pi * u2) }
            i += 2
        }
        return out
    }
}

/// Tiny seedable PRNG (SplitMix64) for reproducible synth noise under
/// `CHATTERBOX_SYNTH_SEED`. Not cryptographic.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
