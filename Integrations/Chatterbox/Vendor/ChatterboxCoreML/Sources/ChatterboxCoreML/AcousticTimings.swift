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
}
