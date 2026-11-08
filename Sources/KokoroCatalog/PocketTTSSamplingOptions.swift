import Foundation

/// Prefer the higher-compute narration configuration. A host may explicitly
/// select fewer steps after measuring its target device; there is no silent
/// device-name, thermal, load-failure or generation-error downgrade.
public struct PocketTTSSamplingOptions: Codable, Hashable, Sendable {
    public static let defaultSamplerSteps = 4
    public var temperature: Float
    public var samplerSteps: Int

    public init(temperature: Float = 0.3, samplerSteps: Int = Self.defaultSamplerSteps) {
        self.temperature = temperature
        self.samplerSteps = samplerSteps
    }

    public enum ValidationError: Error { case invalidTemperature, invalidSamplerSteps }
    public func validate() throws {
        guard temperature.isFinite, temperature >= 0 else { throw ValidationError.invalidTemperature }
        guard (1...8).contains(samplerSteps) else { throw ValidationError.invalidSamplerSteps }
    }

    public var cacheIdentity: String {
        "pocket-sampling-1:temperature\(temperature):steps\(samplerSteps)"
    }
}
