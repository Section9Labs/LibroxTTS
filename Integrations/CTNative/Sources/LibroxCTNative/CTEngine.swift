import CoreML
import Foundation

/// Version 2: all five synthesis graphs use Core ML. No ONNX, Python, cloud,
/// audio session, or downloads.
/// Inference and model lifetime are serialized on this actor. Cancellation is
/// checked before/after every graph (including each of the ten flow steps).
public actor CTEngine {
    public static let sampleRate = 44_100
    public static let runtimeIdentity = "ct-fp32-general-coreml-v2"
    public enum Backend: String, Sendable {
        case coreMLCPU, coreMLGPU, coreMLGPUHeavy, coreMLNeuralEngine, coreMLAll
        public var identity: String { "ct-fp32-general-" + rawValue + "-v2" }
    }
    private let directory: URL
    private let assetIdentity: String
    /// Whole-passage decoding is retained for deterministic equivalence checks.
    public enum VocoderMode: Sendable { case bounded, wholePassage }
    private let vocoderMode: VocoderMode
    private let contextStyleDiagnostic: CTContextStyleDiagnostic.Configuration?
    private var voiceID = CTAssets.voiceID
    private var activeBlend: CTVoiceBlend?
    private var backend: Backend
    private var state: State?
    private struct State {
        let tokenizer: CTTokenizer
        var coreML: [String: CTCoreMLGraph]
        let generator: CTGenerator
        var ttl: CTTensor
        var dp: CTTensor
        var ttlFeature: MLFeatureValue
        var dpFeature: MLFeatureValue
        let totalStep: MLFeatureValue
        let steps: [MLFeatureValue]
        let contextStyleEncoder: CTContextStyleDiagnostic.Encoder?
    }
    private struct Style: Decodable {
        struct Table: Decodable { let data: [[[Float]]]; let dims: [Int] }
        let style_ttl: Table
        let style_dp: Table
    }
    public struct Output: Sendable {
        public let samples: [Float]
        public let predictedDuration: Float
        public let trace: [String: CTTensor]
        public let graphSeconds: [String: Double]
        public let textContextDisposition: TextContextDisposition
    }
    public enum TextContextDisposition: String, Sendable {
        case absent, identity, applied, rejected
    }
    public init(directory: URL, backend: Backend = .coreMLCPU, vocoderMode: VocoderMode = .bounded,
                assetIdentity: String = CTAssets.identity,
                contextStyleDiagnostic: CTContextStyleDiagnostic.Configuration? = nil) {
        self.directory = directory; self.backend = backend; self.vocoderMode = vocoderMode
        self.assetIdentity = assetIdentity
        self.contextStyleDiagnostic = contextStyleDiagnostic
            ?? (assetIdentity == CTApprovedExpression.installationIdentity
                ? CTApprovedExpression.configuration(directory: directory.appendingPathComponent("expression")) : nil)
    }
    public func unload() { state = nil; activeBlend = nil }
    /// Foreground GPU and background CPU share the text models and styles.
    /// Retire heavy allocations before replacement; never hold both backends.
    public func setBackend(_ selection: Backend) throws {
        guard backend != selection else { return }
        let previous = backend
        backend = selection
        guard state != nil else { return }
        if Set([previous, selection]) == Set([Backend.coreMLCPU, .coreMLGPUHeavy]) {
            state?.generator.setBackend(selection)
            state?.coreML.removeValue(forKey: "vocoder")
            do {
                state?.coreML["vocoder"] = try CTCoreMLGraph(
                    package: directory.appendingPathComponent("coreml/vocoder.mlpackage"), backend: selection)
            } catch { state = nil; throw error }
        } else { state = nil; try load() }
    }
    public func load() throws {
        guard state == nil else { return }
        activeBlend = nil
        try Task.checkCancellation()
        try CTAssets.validate(directory, identity: assetIdentity)
        var coreML: [String: CTCoreMLGraph] = [:]
        for name in ["duration_predictor", "text_encoder_early", "text_encoder", "vocoder"] {
            try Task.checkCancellation()
            let selected = backend == .coreMLGPUHeavy && !["vector_estimator", "vocoder"].contains(name)
                ? Backend.coreMLCPU : backend
            coreML[name] = try CTCoreMLGraph(package: directory.appendingPathComponent("coreml/\(name).mlpackage"),
                backend: selected)
        }
        let style = try JSONDecoder().decode(Style.self, from: Data(contentsOf: directory.appendingPathComponent("voice_styles/\(CTAssets.voiceStyles[voiceID]!).json")))
        let ttl = try CTTensor(style.style_ttl.data.flatMap { $0.flatMap { $0 } }, shape: style.style_ttl.dims)
        let dp = try CTTensor(style.style_dp.data.flatMap { $0.flatMap { $0 } }, shape: style.style_dp.dims)
        guard ttl.shape == [1, 50, 256], dp.shape == [1, 8, 16] else { throw CTError.invalidAssets("F1") }
        try Task.checkCancellation()
        state = try State(tokenizer: CTTokenizer(directory: directory), coreML: coreML,
            generator: CTGenerator(package: directory.appendingPathComponent("coreml/vector_estimator.mlpackage"), backend: backend),
            ttl: ttl, dp: dp,
            ttlFeature: CTCoreMLGraph.feature(ttl), dpFeature: CTCoreMLGraph.feature(dp),
            totalStep: CTCoreMLGraph.feature(CTTensor([Float(10)], shape: [1])),
            steps: (0..<10).map { try CTCoreMLGraph.feature(CTTensor([Float($0)], shape: [1])) },
            contextStyleEncoder: contextStyleDiagnostic.map { try CTContextStyleDiagnostic.Encoder(configuration: $0) })
    }
    /// Select pinned styles without reloading graphs. A blend is a deterministic
    /// interpolation of both conditioning tables, never a mix of rendered audio.
    public func setVoice(_ selected: String, blend: CTVoiceBlend? = nil) throws {
        guard CTAssets.voiceStyles[selected] != nil,
              CTAssets.isDKIdentity(assetIdentity) || (selected == CTAssets.voiceID && blend == nil) else { throw CTError.unsupportedVoice }
        guard state != nil else { throw CTError.notLoaded }
        let blend = try blend?.validated(primaryVoiceID: selected)
        guard selected != voiceID || blend != activeBlend else { return }
        func table(_ voice: String) throws -> (CTTensor, CTTensor) {
            guard let name = CTAssets.voiceStyles[voice] else { throw CTError.unsupportedVoice }
            let style = try JSONDecoder().decode(Style.self, from: Data(contentsOf: directory.appendingPathComponent("voice_styles/\(name).json")))
            let ttl = try CTTensor(style.style_ttl.data.flatMap { $0.flatMap { $0 } }, shape: style.style_ttl.dims)
            let dp = try CTTensor(style.style_dp.data.flatMap { $0.flatMap { $0 } }, shape: style.style_dp.dims)
            guard ttl.shape == [1, 50, 256], dp.shape == [1, 8, 16],
                  try ttl.floats().allSatisfy(\.isFinite), try dp.floats().allSatisfy(\.isFinite) else { throw CTError.invalidAssets(name) }
            return (ttl, dp)
        }
        var (ttl, dp) = try table(selected)
        if let blend {
            let (otherTTL, otherDP) = try table(blend.secondaryVoiceID)
            ttl = try blend.interpolate(ttl, otherTTL)
            dp = try blend.interpolate(dp, otherDP)
        }
        let ttlFeature = try CTCoreMLGraph.feature(ttl), dpFeature = try CTCoreMLGraph.feature(dp)
        try Task.checkCancellation()
        state?.ttl = ttl; state?.dp = dp
        state?.ttlFeature = ttlFeature; state?.dpFeature = dpFeature
        voiceID = selected; activeBlend = blend
    }
    /// Saved noise is a diagnostic input, never an integer-seed parity promise.
    /// Voice and language are checked even when callers bypass the app facade.
    public func synthesize(_ text: String, language: String, voiceID: String? = nil,
                           initialNoise: CTTensor? = nil, captureTrace: Bool = false,
                           completeSentence: Bool = true, textContext: CTTextContext.Binding? = nil,
                           expression: CTExpressionInput? = nil) throws -> Output {
        try Task.checkCancellation()
        guard voiceID == nil || voiceID == self.voiceID else { throw CTError.unsupportedVoice }
        guard let state else { throw CTError.notLoaded }
        var trace: [String: CTTensor] = [:]
        var times: [String: Double] = [:]
        func record(_ name: String, _ tensor: CTTensor) { if captureTrace { trace[name] = tensor } }
        func recordFeature(_ name: String, _ feature: MLFeatureValue) throws {
            if captureTrace { trace[name] = try CTCoreMLGraph.tensor(feature) }
        }
        func run(_ name: String, _ inputs: [String: MLFeatureValue], timingKey: String? = nil) throws -> MLFeatureValue {
            try Task.checkCancellation()
            let start = Date()
            let output = try autoreleasepool {
                if name == "vector_estimator" { return try state.generator.predict(inputs) }
                guard let graph = state.coreML[name] else { throw CTError.notLoaded }
                return try graph.predict(inputs)
            }
            times[timingKey ?? name, default: 0] += Date().timeIntervalSince(start)
            try Task.checkCancellation()
            return output
        }
        // Production expression evidence cannot fall through to the older gather algorithm.
        if let expression {
            guard contextStyleDiagnostic?.manifestSHA256 == CTApprovedExpression.manifestSHA256,
                  contextStyleDiagnostic?.carryMode == .linearTwoStep,
                  expression.binding == textContext, activeBlend == nil,
                  CTAssets.isDKIdentity(assetIdentity) else { throw CTError.invalidTensor("expression configuration mismatch") }
        }
        let ids = try state.tokenizer.encode(text, language: language, completeSentence: completeSentence)
        let idsTensor = try CTTensor(ids, shape: [1, ids.count])
        let mask = try CTTensor([Float](repeating: 1, count: ids.count), shape: [1, 1, ids.count])
        record("text_ids", idsTensor); record("text_mask", mask)
        record("style_ttl", state.ttl); record("style_dp", state.dp)
        let idsFeature = try CTCoreMLGraph.feature(idsTensor)
        let maskFeature = try CTCoreMLGraph.feature(mask)
        let duration = try CTCoreMLGraph.tensor(run("duration_predictor", ["text_ids": idsFeature,
            "text_mask": maskFeature, "style_dp": state.dpFeature]))
        record("duration", duration)
        let durations = try duration.floats()
        guard durations.count == 1, let seconds = durations.first, seconds.isFinite, seconds > 0, seconds <= 30 else {
            throw CTError.passageTooLong
        }
        let feed = ["text_ids": idsFeature, "text_mask": maskFeature, "style_ttl": state.ttlFeature]
        let early: MLFeatureValue
        var contextDisposition: TextContextDisposition = textContext == nil ? .absent : .rejected
        var preparedContext: (CTTextContext.Binding, [Int64])?
        if let textContext, !completeSentence, activeBlend == nil, CTAssets.isDKIdentity(assetIdentity),
           let style = CTAssets.voiceStyles[self.voiceID],
           CTTextContext.validates(textContext, spokenText: text, language: language,
               modelFingerprint: try CTTextContext.modelFingerprint(), styleID: style),
           let contextIDs = try? state.tokenizer.encode(textContext.contextText, language: language, completeSentence: false),
           textContext.gatherIndices.count == ids.count,
           textContext.gatherIndices.allSatisfy({ contextIDs.indices.contains($0) }),
           textContext.gatherIndices.map({ contextIDs[$0] }) == ids {
            if textContext.isIdentity { contextDisposition = .identity }
            else { preparedContext = (textContext, contextIDs) }
        }
        if let (textContext, contextIDs) = preparedContext {
            let contextIDTensor = try CTTensor(contextIDs, shape: [1, contextIDs.count])
            let contextMask = try CTTensor([Float](repeating: 1, count: contextIDs.count), shape: [1, 1, contextIDs.count])
            let contextFeed = [
                "text_ids": try CTCoreMLGraph.feature(contextIDTensor),
                "text_mask": try CTCoreMLGraph.feature(contextMask), "style_ttl": state.ttlFeature]
            if let encoder = state.contextStyleEncoder {
                let encoded = try encoder.encode(context: contextFeed, unit: feed, binding: textContext, expression: expression)
                early = encoded.features
                for (name, seconds) in encoded.seconds { times[name, default: 0] += seconds }
                for (name, value) in encoded.diagnosticFeatures { try recordFeature(name, value) }
            } else {
                let encoded = try CTCoreMLGraph.tensor(run("text_encoder_early", contextFeed))
                guard encoded.shape == [1, 256, contextIDs.count] else { throw CTError.invalidTensor("context encoder shape") }
                let values = try encoded.floats()
                var selected: [Float] = []; selected.reserveCapacity(256 * ids.count)
                for channel in 0..<256 {
                    selected += textContext.gatherIndices.map { values[channel * contextIDs.count + $0] }
                }
                early = try CTCoreMLGraph.feature(CTTensor(selected, shape: [1, 256, ids.count]))
            }
            contextDisposition = .applied
            record("context_text_ids", contextIDTensor)
            record("context_gather_indices", try CTTensor(textContext.gatherIndices.map(Int64.init), shape: [ids.count]))
        } else {
            early = try run("text_encoder_early", feed)

        }
        let late = try run("text_encoder", feed)
        try recordFeature("text_emb_early", early); try recordFeature("text_emb_late", late)
        // Preserve numpy float32 duration arithmetic, including its rounding.
        let waveformLength = seconds * Float(Self.sampleRate)
        let latentLength = Int((waveformLength + 3071) / 3072)
        let maskLength = (Int(waveformLength) + 3071) / 3072
        guard latentLength == maskLength, latentLength > 0, latentLength <= 431 else {
            throw CTError.invalidTensor("latent duration")
        }
        let shape = [1, 144, latentLength]
        let initial: CTTensor
        if let initialNoise {
            guard initialNoise.shape == shape, initialNoise.kind == .float32,
                  try initialNoise.floats().allSatisfy(\.isFinite) else { throw CTError.invalidTensor("saved noise") }
            initial = initialNoise
        } else {
            var rng = SystemRandomNumberGenerator()
            var noise: [Float] = []; noise.reserveCapacity(144 * latentLength)
            while noise.count < 144 * latentLength {
                let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
                let v = Double.random(in: 0..<1, using: &rng)
                let magnitude = sqrt(-2 * log(u))
                noise.append(Float(magnitude * cos(2 * .pi * v)))
                if noise.count < 144 * latentLength { noise.append(Float(magnitude * sin(2 * .pi * v))) }
            }
            initial = try CTTensor(noise, shape: shape)
        }
        let latentMask = try CTTensor([Float](repeating: 1, count: latentLength), shape: [1, 1, latentLength])
        record("initial_latent", initial); record("latent_mask", latentMask)
        var latent = try CTCoreMLGraph.feature(initial)
        let latentMaskFeature = try CTCoreMLGraph.feature(latentMask)
        let generatorIDs = try CTCoreMLGraph.paddedText(idsFeature)
        let generatorMask = try CTCoreMLGraph.paddedText(maskFeature)
        let generatorEarly = try CTCoreMLGraph.paddedText(early)
        let generatorLate = try CTCoreMLGraph.paddedText(late)
        var carrySteps: [Int: MLFeatureValue] = [:]
        let carryMode = contextStyleDiagnostic?.carryMode ?? .disabled
        if contextDisposition == .applied, carryMode != .disabled {
            carrySteps = try autoreleasepool {
                let reference = try run("text_encoder_early", feed, timingKey: "context_carry_reference_encoder")
                try recordFeature("context_carry_reference", reference)
                let started = Date()
                let contextualTensor = try CTCoreMLGraph.tensor(early)
                let referenceTensor = try CTCoreMLGraph.tensor(reference)
                let lateTensor = try CTCoreMLGraph.tensor(late)
                let prepared = try CTContextCarry.prepare(contextual: contextualTensor, reference: referenceTensor,
                    late: lateTensor, mode: carryMode)
                record("context_carry_residual", prepared.residual)
                record("context_carry_step3_unpadded", prepared.step3)
                record("context_carry_step4_unpadded", prepared.step4)
                let step3 = try CTCoreMLGraph.paddedText(CTCoreMLGraph.feature(prepared.step3))
                let step4 = try CTCoreMLGraph.paddedText(CTCoreMLGraph.feature(prepared.step4))
                let retainedBytes = [step3, step4].reduce(0) { $0 + ($1.multiArrayValue?.count ?? 0) * 4 }
                // Accounting categories are separate, not an inferred peak sum.
                record("context_carry_payload_bytes", try CTTensor([
                    Float(contextualTensor.data.count + referenceTensor.data.count + lateTensor.data.count),
                    Float(prepared.floatArrayPayloadBytes), Float(prepared.newTensorPayloadBytes), Float(retainedBytes),
                    Float(referenceTensor.data.count)
                ], shape: [5]))
                times["context_carry_prepare", default: 0] += Date().timeIntervalSince(started)
                return [3: step3, 4: step4]
            }
        }
        for step in 0..<10 {
            let conditioning = carrySteps[step] ?? (step < 3 ? generatorEarly : generatorLate)
            if step == 3 || step == 4 { try recordFeature("generator_conditioning_step_\(step)", conditioning) }
            latent = try run("vector_estimator", ["noisy_latent": latent, "text_emb": conditioning,
                "style_ttl": state.ttlFeature, "text_mask": generatorMask, "latent_mask": latentMaskFeature,
                "current_step": state.steps[step], "total_step": state.totalStep, "text_ids": generatorIDs])
            try recordFeature("latent_after_step_\(step)", latent)
            // The two carry buffers are dead immediately after their respective step.
            carrySteps.removeValue(forKey: step)
        }
        let samples: [Float]
        switch vocoderMode {
        case .bounded:
            samples = try CTVocoderWindows.render(latent) { try run("vocoder", ["latent": $0]) }
        case .wholePassage:
            samples = try CTCoreMLGraph.tensor(run("vocoder", ["latent": latent])).floats()
        }
        guard samples.count == latentLength * 3072, samples.allSatisfy(\.isFinite), samples.contains(where: { $0 != 0 }) else {
            throw CTError.invalidAudio
        }
        if captureTrace { record("waveform", try CTTensor(samples, shape: [samples.count])) }
        return Output(samples: samples, predictedDuration: seconds, trace: trace, graphSeconds: times,
                      textContextDisposition: contextDisposition)
    }
}
