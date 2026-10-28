import Foundation

/// Opt-in aggregate timings for the autoregressive loop. Prediction measures the
/// synchronous Core ML API; any synchronization deferred to reading the output is
/// counted in logitsCopyAndCFGSeconds. No per-token logging or thermal polling.
public struct DecodeStepTimings: Sendable, Codable {
    public var iterations: Int = 0
    public var inputPreparationSeconds: TimeInterval = 0
    public var predictionSeconds: TimeInterval = 0
    public var logitsCopyAndCFGSeconds: TimeInterval = 0
    public var samplingSeconds: TimeInterval = 0

    public var accountedSeconds: TimeInterval {
        inputPreparationSeconds + predictionSeconds + logitsCopyAndCFGSeconds + samplingSeconds
    }
}
