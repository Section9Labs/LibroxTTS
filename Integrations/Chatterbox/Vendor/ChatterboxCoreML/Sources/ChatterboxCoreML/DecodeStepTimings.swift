import Foundation

/// Opt-in aggregate timings for the autoregressive loop. Prediction measures the
/// synchronous backend evaluation; synchronization deferred to reading the output
/// is counted in logitsCopyAndCFGSeconds. These are host stage boundaries, not
/// pure GPU kernel timings. Native MLX includes prefill in its iteration totals;
/// the Core ML autoregressive loop reports decode iterations only. No per-token
/// logging or additional resource polling is introduced.
public struct DecodeStepTimings: Sendable, Codable {
    public var iterations: Int = 0
    public var inputPreparationSeconds: TimeInterval = 0
    public var predictionSeconds: TimeInterval = 0
    public var logitsCopyAndCFGSeconds: TimeInterval = 0
    public var samplingSeconds: TimeInterval = 0
    /// Native MLX's existing per-step resource/cancellation guard. nil in older
    /// receipts and backends that do not instrument that boundary.
    public var resourceGuardSeconds: TimeInterval? = nil
    /// Nested parts of native predictionSeconds, never added to accountedSeconds.
    public var graphConstructionSeconds: TimeInterval? = nil
    public var evaluationSeconds: TimeInterval? = nil
    public init() {}

    public var accountedSeconds: TimeInterval {
        inputPreparationSeconds + predictionSeconds + logitsCopyAndCFGSeconds + samplingSeconds + (resourceGuardSeconds ?? 0)
    }
}
