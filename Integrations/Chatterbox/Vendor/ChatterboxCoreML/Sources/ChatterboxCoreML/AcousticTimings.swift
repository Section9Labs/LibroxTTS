import Foundation

/// Numeric stage counters, excluding token decoding and model loading.
public struct ChatterboxAcousticTimings: Sendable, Codable {
    public var encoderSeconds: Double = 0
    public var preparationSeconds: Double = 0
    public var flowSeconds: Double = 0
    public var vocoderSeconds: Double = 0
    public var watermarkSeconds: Double = 0
    public var promptTokens: Int = 0
    public var generatedTokens: Int = 0
    public var windows: Int = 0
    public var flowPredictions: Int = 0
    public var reusedFlowInputBuffers: Bool = false
    public init() {}
}

public struct ChatterboxAcousticOutput: Sendable {
    public let samples: [Float]
    public let timings: ChatterboxAcousticTimings
    public init(samples: [Float], timings: ChatterboxAcousticTimings) {
        self.samples = samples; self.timings = timings
    }
}

/// Library-owned acoustic boundary. No tensors cross this actor boundary.
public protocol ChatterboxAcousticSynthesizing: Sendable {
    func renderMeasured(tokens: [Int], conditioningFile: URL?) async throws -> ChatterboxAcousticOutput
}

/// Explicit implementation and output policy, separated in rendered-audio keys.
public struct ChatterboxAcousticBackend: Sendable {
    public let identifier: String
    public let watermarkPolicy: ChatterboxWatermarkPolicy
    public let synthesizer: any ChatterboxAcousticSynthesizing
    public init(identifier: String, watermarkPolicy: ChatterboxWatermarkPolicy,
                synthesizer: any ChatterboxAcousticSynthesizing) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 256,
              identifier.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) })
        else { throw ChatterboxError.invalidModelOutput("Invalid acoustic backend identity") }
        self.identifier = identifier; self.watermarkPolicy = watermarkPolicy; self.synthesizer = synthesizer
    }
}
