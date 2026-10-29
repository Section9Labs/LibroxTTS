import CoreML
import Foundation

/// On-device voice cloning: a reference recording → a `*-conds.safetensors`
/// identical in schema to the bundled voices and each model's `default-conds`, so the
/// result drops straight into the existing voice picker.
///
/// The five CoreML packages (shipped in each model repo) each take a raw
/// waveform with their DSP front-end baked in; this orchestrator owns only the
/// small host glue (loudness, resample, trim, VE partial striding, FSQ token
/// decode, mean/L2) — no FFT in Swift. The models are fp32 (LSTM/FSQ/StatsPool
/// precision), so they run CPU/GPU, never the ANE; default CU is `cpuAndGPU`,
/// overridable with `CHATTERBOX_VC_CU` (cpu|gpu|ane|all).
///
/// Produces, mirroring `tts.prepare_conditionals`:
///   gen.prompt_feat (MatchaMel, 10 s @24 k) · gen.embedding (CAMPPlus, 10 s @16 k)
///   gen.prompt_token (S3Tokenizer, 10 s @16 k) · t3.cond_prompt_speech_tokens
///   (S3Tokenizer, 15 s @16 k, ≤375) · t3.speaker_emb (VEMel+VELSTM, full @16 k).
public final class VoiceCloner {
    private let matchaMel: MLModel
    private let veMel: MLModel
    private let veLSTM: MLModel
    private let s3tok: MLModel
    private let campplus: MLModel
    private let encoderConditioningSeconds: Int

    private let s3GenSR = 24000.0
    private let s3SR = 16000.0
    private let mel = Constants.melBins   // 80

    // VE partial striding (voice_encoder: ve_partial_frames=160, rate=1.3 -> step 77).
    private let vePartialFrames = 160
    private let veFrameStep = 77

    /// Loads the five conditioning models from a directory (`.mlpackage` or
    /// `.mlmodelc`). Same resolution + on-load compile convention as
    /// `ChatterboxCoreMLModel.load`.
    public init(modelDirectory: URL, computeUnits: MLComputeUnits? = nil,
                encoderConditioningSeconds: Int = 15,
                modelComputeUnits: [String: MLComputeUnits] = [:]) async throws {
        guard (1...15).contains(encoderConditioningSeconds),
              Set(modelComputeUnits.keys).isSubset(of: ["MatchaMel", "VEMel", "VELSTM", "S3Tokenizer", "CAMPPlus"]) else {
            throw ChatterboxError.invalidModelOutput("invalid reference conditioning configuration")
        }
        self.encoderConditioningSeconds = encoderConditioningSeconds
        func cu() -> MLComputeUnits {
            switch ProcessInfo.processInfo.environment["CHATTERBOX_VC_CU"]?.lowercased() {
            case "cpu", "cpuonly": return .cpuOnly
            case "ane", "ne": return .cpuAndNeuralEngine
            case "all": return .all
            default: return .cpuAndGPU
            }
        }
        let units = computeUnits ?? cu()
        func load(_ names: [String]) async throws -> MLModel {
            for n in names {
                let url = modelDirectory.appendingPathComponent(n)
                if FileManager.default.fileExists(atPath: url.path) {
                    let cfg = MLModelConfiguration()
                    cfg.computeUnits = modelComputeUnits[url.deletingPathExtension().lastPathComponent] ?? units
                    let compiled = try await ChatterboxCoreMLModel.compiledModel(at: url)
                    return try MLModel(contentsOf: compiled, configuration: cfg)
                }
            }
            throw ChatterboxError.invalidModelOutput("VoiceCloner: none of \(names) in \(modelDirectory.path)")
        }
        matchaMel = try await load(["MatchaMel.mlmodelc", "MatchaMel.mlpackage"])
        veMel = try await load(["VEMel.mlmodelc", "VEMel.mlpackage"])
        veLSTM = try await load(["VELSTM.mlmodelc", "VELSTM.mlpackage"])
        s3tok = try await load(["S3Tokenizer.mlmodelc", "S3Tokenizer.mlpackage"])
        campplus = try await load(["CAMPPlus.mlmodelc", "CAMPPlus.mlpackage"])
    }

    /// Clones the voice in `audioURL` into a conditioning file at `outputURL`.
    public func cloneVoice(from audioURL: URL, to outputURL: URL) throws {
        let conds = try makeConditionals(from: audioURL)
        try conds.write(to: outputURL)
    }

    /// Builds `Conditionals` from a reference audio file. Internal: `Conditionals`
    /// is module-internal; the app uses `cloneVoice(from:to:)`, tests use `@testable`.
    func makeConditionals(from audioURL: URL) throws -> Conditionals {
        let raw24 = try AudioIO.loadMono(url: audioURL, targetSampleRate: s3GenSR)
        return try makeConditionals(fromSamples24k: raw24)
    }

    /// Builds `Conditionals` from already-decoded 24 kHz mono samples. Split out so
    /// tests can feed the exact wav the Python oracle used (isolating model+glue
    /// parity from resampler/decoder differences).
    func makeConditionals(fromSamples24k raw24: [Float]) throws -> Conditionals {
        // Upstream imposes **no** minimum: `ChatterboxTTS.prepare_conditionals` simply
        // slices the reference to `DEC_COND_LEN`/`ENC_COND_LEN` and runs, and the demo
        // prompts Resemble AI publishes for their own apps are routinely 1.4-4 s. This
        // guard used to reject anything under 5 s, which refused ten of upstream's
        // twenty-three prompts — English among them — for no reason the models share.
        //
        // The structural floor is far lower: `veNumWins` always yields at least one
        // 160-frame partial and zero-pads the mel up to it, and every other stage
        // (MatchaMel, S3Tokenizer, CAMPPlus) is length-agnostic. So the guard now
        // rejects only what cannot be speech at all, and the 5 s figure survives as
        // what it always was — a quality expectation, logged rather than enforced.
        // Fewer partials mean the speaker embedding is averaged over less evidence, so
        // a short prompt clones less stably; it does not clone *wrongly*.
        let seconds = Double(raw24.count) / s3GenSR
        guard seconds >= 1.0 else {
            throw ChatterboxError.invalidModelOutput(
                "audio prompt is \(String(format: "%.2f", seconds))s — need at least 1s of speech")
        }
        if seconds < 5.0 {
            Log.pipeline.notice(
                "[clone] short prompt (\(String(format: "%.2f", seconds), privacy: .public)s) — speaker embedding averages fewer partials; expect a less stable clone")
        }
        // Loudness-normalize @24 k (matches tts.norm_loudness), then derive the
        // 16 k stream and the 10 s / 15 s windows.
        let wav24 = AudioIO.normalizeLoudness(raw24, sampleRate: s3GenSR)
        let wav16 = AudioIO.resample(wav24, from: s3GenSR, to: s3SR)
        let clip24 = Array(wav24.prefix(Int(10 * s3GenSR)))          // DEC_COND_LEN
        let clip16 = AudioIO.resample(clip24, from: s3GenSR, to: s3SR)
        let enc16 = Array(wav16.prefix(Int(Double(encoderConditioningSeconds) * s3SR)))

        // gen.prompt_feat — MatchaMel(clip24): (1,80,T) -> store as (T,80) C-order.
        let (feat, featFrames) = try promptFeat(clip24)

        // gen.embedding — CAMPPlus(clip16): (1,192).
        let genEmb = try run(campplus, wav: clip16, output: "out")

        // gen.prompt_token — S3Tokenizer(clip16), trimmed to featFrames/2 so
        // mel_len == 2*token_len (matches embed_ref's alignment fixup).
        var genTokens = try tokens(clip16)
        let maxGen = featFrames / 2
        if genTokens.count > maxGen { genTokens = Array(genTokens.prefix(maxGen)) }

        // Legacy default 15s/375; the multilingual V3 adapter explicitly uses 6s/150.
        var condTokens = try tokens(enc16)
        let maxConditioningTokens = encoderConditioningSeconds * 25
        if condTokens.count > maxConditioningTokens { condTokens = Array(condTokens.prefix(maxConditioningTokens)) }

        // t3.speaker_emb — VE chain on the full 16 k stream.
        let speakerEmb = try speakerEmbedding(wav16)

        return Conditionals(
            speakerEmb: speakerEmb,
            condPromptSpeechTokens: condTokens,
            genEmbedding: genEmb,
            promptTokens: genTokens,
            promptFeat: feat)
    }

    // MARK: - Per-model steps

    /// MatchaMel(wav) (1,80,T) -> (feat flattened (T,80) C-order, T).
    private func promptFeat(_ wav: [Float]) throws -> ([Float], Int) {
        let arr = try predict(matchaMel, wav: wav, output: "out")
        let shape = arr.shape.map { $0.intValue }
        guard shape.count == 3, shape[1] == mel else {
            throw ChatterboxError.invalidModelOutput("MatchaMel shape \(shape) != (1,80,T)")
        }
        let t = shape[2]
        let flat = try arr.toFloatArrayAnyPrecision()                   // (80*T) C-order [m*T + f]
        var out = [Float](repeating: 0, count: t * mel)             // (T,80) C-order [f*80 + m]
        for m in 0..<mel {
            let base = m * t
            for f in 0..<t { out[f * mel + m] = flat[base + f] }
        }
        return (out, t)
    }

    /// S3Tokenizer(wav) -> FSQ tokens via round()+1 + base-3 sum (host side).
    private func tokens(_ wav: [Float]) throws -> [Int32] {
        let arr = try predict(s3tok, wav: wav, output: "out")
        let shape = arr.shape.map { $0.intValue }
        guard shape.count == 3, shape[2] == 8 else {
            throw ChatterboxError.invalidModelOutput("S3Tokenizer shape \(shape) != (1,T,8)")
        }
        let tdim = shape[1]
        let h = try arr.toFloatArrayAnyPrecision()                      // (T*8) C-order
        var out = [Int32](repeating: 0, count: tdim)
        let powers: [Int32] = [1, 3, 9, 27, 81, 243, 729, 2187]     // 3^0..3^7
        for t in 0..<tdim {
            var mu: Int32 = 0
            let base = t * 8
            for d in 0..<8 {
                let q = Int32((h[base + d]).rounded()) + 1          // round()+1 -> {0,1,2}
                mu += q * powers[d]
            }
            out[t] = mu
        }
        return out
    }

    /// VE chain: trim -> VEMel (1,T,40) -> stride into (N,160,40) -> VELSTM (N,256)
    /// -> mean over N -> L2. Reproduces `ve.embeds_from_wavs([wav]).mean(0)`.
    private func speakerEmbedding(_ wav16: [Float]) throws -> [Float] {
        let trimmed = AudioIO.trim(wav16, topDB: 20)
        let melArr = try predict(veMel, wav: trimmed, output: "out")
        let shape = melArr.shape.map { $0.intValue }
        guard shape.count == 3, shape[2] == 40 else {
            throw ChatterboxError.invalidModelOutput("VEMel shape \(shape) != (1,T,40)")
        }
        let t = shape[1]
        let melFlat = try melArr.toFloatArrayAnyPrecision()             // (T*40) C-order [f*40 + c]

        // Number of partials + target length (voice_encoder.get_num_wins).
        let win = vePartialFrames, step = veFrameStep
        let (nPartials, targetLen) = veNumWins(nFrames: t, step: step, minCoverage: 0.8)
        // Pad (zeros) or trim the mel to targetLen frames.
        var padded = melFlat
        if targetLen > t {
            padded.append(contentsOf: [Float](repeating: 0, count: (targetLen - t) * 40))
        } else if targetLen < t {
            padded = Array(padded.prefix(targetLen * 40))
        }
        // Overlapping partials (N,160,40), C-order.
        var partials = [Float](repeating: 0, count: nPartials * win * 40)
        for p in 0..<nPartials {
            let srcFrame = p * step
            for f in 0..<win {
                let src = (srcFrame + f) * 40
                let dst = (p * win + f) * 40
                for c in 0..<40 { partials[dst + c] = padded[src + c] }
            }
        }
        let embArr = try predict(veLSTM,
                                 inputs: ["partials": MLMultiArray.float32(partials, shape: [nPartials, win, 40])],
                                 output: "embeds")
        let emb = try embArr.toFloatArrayAnyPrecision()                 // (N,256)
        // Mean over partials, then L2-normalize (utt_to_spk_embed).
        var raw = [Float](repeating: 0, count: Constants.speakerEmbDim)
        for p in 0..<nPartials {
            let base = p * Constants.speakerEmbDim
            for d in 0..<Constants.speakerEmbDim { raw[d] += emb[base + d] }
        }
        let inv = 1.0 / Float(nPartials)
        for d in 0..<raw.count { raw[d] *= inv }
        let norm = max(sqrt(raw.reduce(0) { $0 + $1 * $1 }), 1e-12)
        return raw.map { $0 / norm }
    }

    /// Port of voice_encoder.get_num_wins (step, min_coverage) -> (n_wins, target_len).
    private func veNumWins(nFrames: Int, step: Int, minCoverage: Double) -> (Int, Int) {
        let win = vePartialFrames
        let base = max(nFrames - win + step, 0)
        var nWins = base / step
        let rem = base % step
        if nWins == 0 || Double(rem + (win - step)) / Double(win) >= minCoverage { nWins += 1 }
        let target = win + step * (nWins - 1)
        return (nWins, target)
    }

    // MARK: - CoreML predict helpers

    private func run(_ model: MLModel, wav: [Float], output: String) throws -> [Float] {
        try predict(model, wav: wav, output: output).toFloatArrayAnyPrecision()
    }

    private func predict(_ model: MLModel, wav: [Float], output: String) throws -> MLMultiArray {
        try predict(model, inputs: ["wav": MLMultiArray.float32(wav, shape: [1, wav.count])], output: output)
    }

    private func predict(_ model: MLModel, inputs: [String: MLMultiArray], output: String) throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(
            dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        let out = try predictTrapping(model, from: provider, label: "voice-cloner[\(output)]")
        guard let arr = out.featureValue(for: output)?.multiArrayValue else {
            throw ChatterboxError.invalidModelOutput("voice-cloner model missing output '\(output)'")
        }
        return arr
    }
}
