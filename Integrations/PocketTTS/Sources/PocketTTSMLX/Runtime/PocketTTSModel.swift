import KokoroCatalog
import Foundation
@preconcurrency import MLX
import MLXNN

private let defaultAudioPrompt: String = "alba"

public struct PocketTTSState {
    public var flowCache: [KVCacheSimple]
}

public final class PocketTTSModel: Module {
    private(set) var diagnosticTokenCount: Int?
    private(set) var diagnosticFrameIndex: Int?
    public let config: PocketTTSModelConfig
    private let modelFolder: URL
    @ModuleInfo(key: "flow_lm") public var flow_lm: FlowLMModel
    @ModuleInfo(key: "mimi") public var mimi: MimiAdapter

    public var temp: Float
    public var lsd_decode_steps: Int
    public var noise_clamp: Float?
    public var eos_threshold: Float

    public var sampleRate: Int { config.mimi.sampleRate }
    private init(config: PocketTTSModelConfig, modelFolder: URL, flowLM: FlowLMModel, mimi: MimiAdapter) {
        self.config = config
        self.modelFolder = modelFolder
        self._flow_lm = ModuleInfo(wrappedValue: flowLM)
        self._mimi = ModuleInfo(wrappedValue: mimi)
        self.temp = config.temp
        self.lsd_decode_steps = config.lsdDecodeSteps
        self.noise_clamp = config.noiseClamp
        self.eos_threshold = config.eosThreshold
        super.init()
    }

    public static func fromConfig(
        _ config: PocketTTSModelConfig, modelFolder: URL, encoderEnabled: Bool? = nil
    ) throws -> PocketTTSModel {
        guard config.fuser.cross.isEmpty, config.fuser.streamingSum.isEmpty,
              Set(config.fuser.sum).isSubset(of: ["num_speakers", "duration_delta"]) else {
            throw modelError("Unsupported Pocket TTS conditioning fuser")
        }
        guard ["rms", "rms_var"].contains(config.flowLM.timeRmsNorm),
              ["erf", "tanh"].contains(config.flowLM.transformer.gelu),
              ["erf", "tanh"].contains(config.mimi.gelu) else {
            throw modelError("Unsupported timestep normalization or GELU activation")
        }
        var numSpeakers: SpeakerCountConditioner?
        var durationDelta: ContinuousConditioner?
        for conditioner in config.conditioners {
            if conditioner.name == "num_speakers", conditioner.type == "lut", let lut = conditioner.lut {
                numSpeakers = SpeakerCountConditioner(
                    nBins: lut.nBins, dim: lut.dim, outputDim: config.flowLM.transformer.dModel)
            } else if conditioner.name == "duration_delta", conditioner.type == "continuous", let continuous = conditioner.continuous {
                guard continuous.dim >= 4, continuous.dim % 2 == 0 else {
                    throw modelError("Continuous conditioning requires an even dim >= 4")
                }
                durationDelta = ContinuousConditioner(
                    dim: continuous.dim, outputDim: config.flowLM.transformer.dModel,
                    scaleFactor: continuous.scaleFactor, maxPeriod: continuous.maxPeriod)
            } else {
                throw modelError("Unsupported conditioner: \(conditioner.name)")
            }
        }
        let flowLM = try FlowLMModel.fromConfig(
            config.flowLM,
            latentDim: config.flowLM.ldim ?? config.mimi.quantizer.dimension,
            modelFolder: modelFolder,
            tokenizerPath: config.tokenizerName,
            numSpeakers: numSpeakers,
            durationDelta: durationDelta
        )
        let mimi = MimiAdapter.fromConfig(config.mimi, encoderEnabled: encoderEnabled)
        let model = PocketTTSModel(config: config, modelFolder: modelFolder, flowLM: flowLM, mimi: mimi)
        try model.validateSampling()
        return model
    }

    private static func modelError(_ message: String) -> NSError {
        NSError(domain: "PocketTTSModel", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func validateSampling() throws {
        guard lsd_decode_steps > 0, temp.isFinite, temp >= 0,
              noise_clamp.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw Self.modelError("Sampling requires positive lsd_decode_steps and finite, nonnegative temperature and noise_clamp")
        }
    }

    public func initState() -> PocketTTSState {
        PocketTTSState(flowCache: flow_lm.makeCache())
    }

    private func runFlowLM(
        _ state: inout PocketTTSState,
        textTokens: MLXArray,
        backboneInputLatents: MLXArray,
        audioConditioning: MLXArray
    ) -> (MLXArray, MLXArray)? {
        let textEmb = textTokens.shape[1] > 0
            ? flow_lm.conditioner(TokenizedText(tokens: textTokens))
            : MLXArray.zeros([1, 0, flow_lm.dim])
        let combined = concatenated([textEmb, audioConditioning], axis: 1)
        if backboneInputLatents.shape[1] == 0 {
            if combined.shape[1] > 0 {
                _ = flow_lm.transformer(combined.asType(.float32), cache: state.flowCache)
            }
            // Match the reference RNG sequence without evaluating an unused latent.
            _ = MLXRandom.normal([1, flow_lm.ldim])
            return nil
        }
        let (out, isEos) = flow_lm(
            sequence: backboneInputLatents,
            textEmbeddings: combined,
            cache: state.flowCache,
            lsdDecodeSteps: lsd_decode_steps,
            temperature: temp,
            noiseClamp: noise_clamp,
            eosThreshold: eos_threshold
        )
        let outExpanded = out.expandedDimensions(axis: 1)
        return (outExpanded, isEos)
    }

    private func runFlowLMAndIncrementStep(
        _ state: inout PocketTTSState,
        textTokens: MLXArray? = nil,
        backboneInputLatents: MLXArray? = nil,
        audioConditioning: MLXArray? = nil
    ) -> (MLXArray, MLXArray)? {
        let tokens = textTokens ?? MLXArray.zeros([1, 0], type: Int32.self)
        let backbone = backboneInputLatents ?? MLXArray.zeros([1, 0, flow_lm.ldim])
        let conditioning = audioConditioning ?? MLXArray.zeros([1, 0, flow_lm.dim])
        return runFlowLM(&state, textTokens: tokens, backboneInputLatents: backbone, audioConditioning: conditioning)
    }

    // Kyutai ships language/model-specific prefilled KV states, not raw voice vectors.
    // These already include BOS-before-voice. Never prepend it a second time.
    public func loadVoiceState(_ name: String) throws -> PocketTTSState {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw Self.modelError("Invalid voice name")
        }
        let tensors = try MLX.loadArrays(url: modelFolder.appendingPathComponent("embeddings/\(name).safetensors"))
        let state = initState()
        for (i, cache) in state.flowCache.enumerated() {
            let prefix = "transformer.layers.\(i).self_attn/"
            guard let kv = tensors[prefix + "cache"], let offsetArray = tensors[prefix + "offset"],
                  kv.ndim == 5, kv.shape[0] == 2, kv.shape[1] == 1,
                  kv.shape[3] == config.flowLM.transformer.numHeads,
                  kv.shape[4] == flow_lm.dim / config.flowLM.transformer.numHeads else {
                throw Self.modelError("Voice state does not match this model")
            }
            let offset = offsetArray.item(Int.self)
            guard offset > 0, offset <= kv.shape[2], offset <= 512 else { throw Self.modelError("Invalid voice cache length") }
            cache.state = [kv[0, 0..., ..<offset, 0..., 0...].transposed(0, 2, 1, 3).asType(.float32),
                           kv[1, 0..., ..<offset, 0..., 0...].transposed(0, 2, 1, 3).asType(.float32)]
        }
        return state
    }

    private func sliceFlowCache(_ state: inout PocketTTSState, to length: Int) {
        let targetLength = max(length, 0)
        for cache in state.flowCache {
            let s = cache.state
            guard s.count == 2 else { continue }
            let keys = s[0]
            let values = s[1]
            let end = min(targetLength, keys.shape[2])
            let slicedKeys = keys[.ellipsis, ..<end, 0...]
            let slicedValues = values[.ellipsis, ..<end, 0...]
            cache.state = [slicedKeys, slicedValues]
            cache.offset = min(cache.offset, end)
        }
    }

    private func getFlowCacheNumFrames(_ state: PocketTTSState) -> Int {
        for cache in state.flowCache {
            let s = cache.state
            guard s.count == 2 else { continue }
            let keys = s[0]
            return min(cache.offset, keys.shape[2])
        }
        return 0
    }

    public func chunkPlan(text: String, language: String, role: PocketTTSPassageRole,
                          options: PocketTTSChunkingOptions) throws -> [PocketTTSTextChunk] {
        try PocketTTSPassageChunker.plan(text, language: language, role: role, options: options,
            prepare: { try PocketTTSTextUtils.prepareTextPrompt($0, config: self.config).0 },
            tokenCount: { self.flow_lm.conditioner.tokenizer.encode($0).count })
    }

    /// Synchronous callback supplies natural 80 ms codec frames and backpressure.
    /// Keep this object inside one actor; a model contains mutable decoder state.
    public func render(text: String, voice: String, continuation: Bool = true,
                       chunking: PocketTTSChunkingOptions = .init(),
                       role: PocketTTSPassageRole = .narration, language: String = "en",
                       checkpoint: (String) throws -> Void = { _ in },
                       onChunk: ([Float]) throws -> Void) throws {
        try validateSampling()
        defer { mimi.resetState(); diagnosticTokenCount = nil; diagnosticFrameIndex = nil }
        try checkpoint("before-voice")
        var state = try loadVoiceState(voice)
        let promptFrames = getFlowCacheNumFrames(state)
        let chunks = try chunkPlan(text: text, language: language, role: role, options: chunking)
        var previousText: String?
        var previousLatents: [MLXArray] = []
        for decision in chunks {
            try Task.checkCancellation()
            let chunk = decision.text
            if decision.startsNewPassage { previousText = nil; previousLatents = [] }
            sliceFlowCache(&state, to: promptFrames)
            let forced = continuation && !previousLatents.isEmpty ? concatenated(previousLatents, axis: 1) : nil
            let joined = forced == nil ? chunk : (previousText! + " " + chunk)
            let (preparedText, _) = try PocketTTSTextUtils.prepareTextPrompt(joined, config: config)
            let (_, tail) = try PocketTTSTextUtils.prepareTextPrompt(chunk, config: config)
            previousLatents = try renderChunk(state: &state, text: preparedText, forced: forced,
                framesAfterEOS: config.framesAfterEOS ?? tail + 2, checkpoint: checkpoint, onChunk: onChunk)
            previousText = chunk
        }
    }

    private var modelFadeSamples: Int { sampleRate / 200 }

    private func renderChunk(state: inout PocketTTSState, text: String, forced: MLXArray?,
                             framesAfterEOS: Int, checkpoint: (String) throws -> Void, onChunk: ([Float]) throws -> Void) throws -> [MLXArray] {
        mimi.resetState()
        defer { mimi.resetState() }
        try checkpoint("before-prefill")
        let prepared = flow_lm.conditioner.prepare(text)
        diagnosticTokenCount = prepared.tokens.shape[1]
        let maxFrames = min(1500, Int(ceil((Double(prepared.tokens.shape[1]) / 3 + 2) * mimi.frameRate)))
        var input = MLXArray.ones([1, 1, flow_lm.ldim]) * Float.nan
        if let forced {
            let n = forced.shape[1]
            let prefill = concatenated([input, forced[0..., ..<(n - 1), 0...]], axis: 1)
            _ = runFlowLMAndIncrementStep(&state, textTokens: prepared.tokens, backboneInputLatents: prefill)
            input = forced[0..., (n - 1)..<n, 0...]
            // Match latest Kyutai: warm Mimi with the previous 12 frames, discard that PCM.
            for i in max(0, n - 12)..<n {
                try Task.checkCancellation()
                try checkpoint("codec-warmup")
                let latent = forced[0..., i..<(i + 1), 0...] * flow_lm.emb_std + flow_lm.emb_mean
                eval(mimi.decodeStep(mimi.quantizer(latent.transposed(0, 2, 1))))
            }
        } else {
            _ = runFlowLMAndIncrementStep(&state, textTokens: prepared.tokens)
        }
        try Task.checkCancellation()
        eval(state.flowCache.flatMap(\.state))
        try checkpoint("after-prefill")
        var eosStep: Int?
        var latents: [MLXArray] = []
        for step in 0..<maxFrames {
            diagnosticFrameIndex = step
            try Task.checkCancellation()
            try checkpoint("before-flow")
            guard let (next, eos) = runFlowLMAndIncrementStep(&state, backboneInputLatents: input) else {
                throw Self.modelError("Missing generated frame")
            }
            try Task.checkCancellation()
            if eosStep == nil, step >= 6, eos.item(Bool.self) { eosStep = step }
            if let eosStep, step >= eosStep + framesAfterEOS { return latents }
            try checkpoint("before-codec")
            let latent = next * flow_lm.emb_std + flow_lm.emb_mean
            let audio = mimi.decodeStep(mimi.quantizer(latent.transposed(0, 2, 1)))[0, 0]
            try Task.checkCancellation()
            eval(audio, next)
            try Task.checkCancellation()
            var samples = audio.asArray(Float.self)
            if step == 0 && forced == nil {
                let n = min(samples.count, modelFadeSamples)
                for i in 0..<n { samples[i] *= Float(i) / Float(max(1, modelFadeSamples - 1)) }
            }
            guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite }) else { throw Self.modelError("Invalid audio") }
            try checkpoint("after-codec")
            try onChunk(samples)
            latents.append(next)
            input = next
        }
        // Never commit a truncated chapter as complete.
        throw Self.modelError("Generation limit reached without completed EOS")
    }

    public static func fromModelDirectory(_ directory: URL,
                                          checkpoint: (String) throws -> Void = { _ in }) throws -> PocketTTSModel {
        try Task.checkCancellation()
        try checkpoint("load-config")
        let config = try PocketTTSModelConfig.load(from: directory.appendingPathComponent("config.json"))
        var raw = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        try checkpoint("load-weights")
        let model = try fromConfig(config, modelFolder: directory, encoderEnabled: false)
        let weights = try model.sanitize(weights: &raw, checkpoint: checkpoint)
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .all)
        try Task.checkCancellation()
        try checkpoint("load-conditioning")
        model.flow_lm.cacheConditioning()
        try Task.checkCancellation()
        eval(model)
        try Task.checkCancellation()
        try checkpoint("load-complete")
        return model
    }
}
