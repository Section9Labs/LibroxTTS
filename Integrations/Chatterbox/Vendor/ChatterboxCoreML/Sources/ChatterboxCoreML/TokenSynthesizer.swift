import Foundation
import CoreML
import PerthCoreML

/// Acoustic-only seam for an independently validated token decoder. Loads no
/// Core ML T3 model. Calls are serialized; the host retains playback ownership.
public actor ChatterboxTokenSynthesizer {
    private let synth: SynthRunner
    private let conditioning: Conditionals
    private let watermark: PerthWatermarker

    public init(modelDirectory: URL, conditioningFile: URL, watermarkDirectory: URL,
                computeUnits: PipelineComputeUnits) async throws {
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
        synth = try SynthRunner(encoderURL: encoder, cfmURL: flow, vocoderURL: vocoder, computeUnits: computeUnits)
        watermark = try PerthWatermarker(modelDirectory: watermarkDirectory, computeUnits: computeUnits.watermark ?? .cpuOnly)
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
        try render(tokens: tokens, conditioning: conditioning)
    }

    public func render(tokens: [Int], conditioningFile: URL) throws -> [Float] {
        try ChatterboxVoiceFile.validate(at: conditioningFile)
        return try render(tokens: tokens, conditioning: Conditionals(contentsOf: conditioningFile))
    }

    private func render(tokens: [Int], conditioning: Conditionals) throws -> [Float] {
        guard !tokens.isEmpty, tokens.count <= 1_000, tokens.allSatisfy({ (0..<6561).contains($0) })
        else { throw ChatterboxError.invalidModelOutput("Invalid or unbounded speech tokens") }
        try Task.checkCancellation()
        let samples = try synth.synthesize(generatedTokens: tokens, conds: conditioning)
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.count <= 24_000 * 120, samples.allSatisfy(\.isFinite)
        else { throw ChatterboxError.invalidModelOutput("Invalid synthesized audio") }
        let marked = try watermark.applyWatermark(samples, sampleRate: 24_000)
        guard marked.count == samples.count, marked.allSatisfy(\.isFinite)
        else { throw ChatterboxError.invalidModelOutput("Invalid watermarked audio") }
        return marked
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
