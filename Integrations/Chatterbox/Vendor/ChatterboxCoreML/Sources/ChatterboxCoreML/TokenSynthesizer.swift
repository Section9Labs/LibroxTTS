import Foundation
import CoreML
import PerthCoreML

/// Explicit output policy. A disabled watermark is never an automatic recovery
/// from a failed Perth load. Rendered-audio caches must include this selection.
public enum ChatterboxWatermarkPolicy: String, Sendable, Codable {
    case perth = "perth-1"
    case disabled = "disabled-1"
}

/// Acoustic-only seam for an independently validated token decoder. Loads no
/// Core ML T3 model. Calls are serialized; the host retains playback ownership.
public actor ChatterboxTokenSynthesizer: ChatterboxAcousticSynthesizing {
    private let synth: SynthRunner
    private let conditioning: Conditionals
    private let watermark: PerthWatermarker?

    public init(modelDirectory: URL, conditioningFile: URL, watermarkDirectory: URL,
                computeUnits: PipelineComputeUnits, reuseFlowInputs: Bool = false,
                watermarkPolicy: ChatterboxWatermarkPolicy = .perth) async throws {
        let encoder = try await Self.compiled("S3Encoder", directory: modelDirectory)
        let flow = try await Self.compiled("S3CFM", directory: modelDirectory)
        let vocoder = try await Self.compiled("S3Vocoder", directory: modelDirectory)
        try Task.checkCancellation()
        let conditioning = try Conditionals(contentsOf: conditioningFile)
        guard conditioning.speakerEmb.count == 256, conditioning.genEmbedding.count == 192,
              !conditioning.promptTokens.isEmpty, conditioning.promptTokens.count <= 750,
              !conditioning.promptFeat.isEmpty, conditioning.promptFeat.count % 80 == 0,
              conditioning.genEmbedding.allSatisfy(\.isFinite), conditioning.promptFeat.allSatisfy(\.isFinite)
        else { throw ChatterboxError.invalidModelOutput("Invalid acoustic conditioning") }
        self.conditioning = conditioning
        synth = try SynthRunner(encoderURL: encoder, cfmURL: flow, vocoderURL: vocoder,
                               computeUnits: computeUnits, reuseFlowInputs: reuseFlowInputs)
        switch watermarkPolicy {
        case .perth:
            watermark = try PerthWatermarker(modelDirectory: watermarkDirectory, computeUnits: computeUnits.watermark ?? .cpuOnly)
        case .disabled:
            watermark = nil
        }
    }

    private nonisolated static func compiled(_ name: String, directory: URL) async throws -> URL {
        for suffix in ["mlmodelc", "mlpackage"] {
            let url = directory.appendingPathComponent(name + "." + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                return try await ChatterboxCoreMLModel.compiledModel(at: url)
            }
        }
        throw ChatterboxError.invalidModelOutput("Missing acoustic model: \(name)")
    }

    public func render(tokens: [Int]) throws -> [Float] {
        try renderMeasured(tokens: tokens, conditioning: conditioning).samples
    }

    public func render(tokens: [Int], conditioningFile: URL) throws -> [Float] {
        try ChatterboxVoiceFile.validate(at: conditioningFile)
        return try renderMeasured(tokens: tokens, conditioning: Conditionals(contentsOf: conditioningFile)).samples
    }

    public func renderMeasured(tokens: [Int], conditioningFile: URL? = nil) throws -> ChatterboxAcousticOutput {
        if let conditioningFile {
            try ChatterboxVoiceFile.validate(at: conditioningFile)
            return try renderMeasured(tokens: tokens, conditioning: Conditionals(contentsOf: conditioningFile))
        }
        return try renderMeasured(tokens: tokens, conditioning: conditioning)
    }

    private func renderMeasured(tokens: [Int], conditioning: Conditionals) throws -> ChatterboxAcousticOutput {
        guard !tokens.isEmpty, tokens.count <= 1_000, tokens.allSatisfy({ (0..<6561).contains($0) })
        else { throw ChatterboxError.invalidModelOutput("Invalid or unbounded speech tokens") }
        try Task.checkCancellation()
        let output = try synth.synthesizeMeasured(generatedTokens: tokens, conds: conditioning)
        let samples = output.samples
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.count <= 24_000 * 120, samples.allSatisfy(\.isFinite)
        else { throw ChatterboxError.invalidModelOutput("Invalid synthesized audio") }
        guard let watermark else {
            var timings = output.timings
            timings.watermarkSeconds = 0
            return .init(samples: samples, timings: timings)
        }
        let began = Date()
        let marked = try watermark.applyWatermark(samples, sampleRate: 24_000)
        guard marked.count == samples.count, marked.allSatisfy(\.isFinite)
        else { throw ChatterboxError.invalidModelOutput("Invalid watermarked audio") }
        var timings = output.timings
        timings.watermarkSeconds = Date().timeIntervalSince(began)
        return .init(samples: marked, timings: timings)
    }
}

/// Shared host sampling policy for alternative token decoders. This delegates to
/// the Core ML adapter sampler; it is not an official PyTorch sampler-parity claim.
public struct ChatterboxSpeechSampler {
    private var sampler: Sampler
    public init(options: GenerationOptions) { sampler = Sampler(options: options) }
    public mutating func sample(logits: [Float], previous: [Int], minTokensReached: Bool) -> Int {
        sampler.sample(logits: logits, previous: previous, minTokensReached: minTokensReached)
    }
}
