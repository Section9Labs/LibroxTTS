import Foundation

/// Explicit native style interpolation. No model graphs, audio or voice state
/// are duplicated. Zero weight and self-blends resolve to the original style.
public struct CTVoiceBlend: Sendable, Equatable {
    public let secondaryVoiceID: String
    public let weight: Float
    public init(secondaryVoiceID: String, weight: Float) {
        self.secondaryVoiceID = secondaryVoiceID; self.weight = weight
    }
    public static let revision = "native-style-blend-1"
    public var cacheIdentity: String { "\(Self.revision):\(secondaryVoiceID):\(weight)" }
    public func validated(primaryVoiceID: String) throws -> Self? {
        guard CTAssets.voiceStyles[primaryVoiceID] != nil,
              CTAssets.voiceStyles[secondaryVoiceID] != nil else { throw CTError.unsupportedVoice }
        guard weight.isFinite, (0...1).contains(weight) else { throw CTError.invalidTensor("voice blend weight") }
        return weight == 0 || secondaryVoiceID == primaryVoiceID ? nil : self
    }
    func interpolate(_ primary: CTTensor, _ secondary: CTTensor) throws -> CTTensor {
        guard primary.shape == secondary.shape, primary.kind == .float32, secondary.kind == .float32,
              weight.isFinite, (0...1).contains(weight) else { throw CTError.invalidTensor("voice blend") }
        let a = try primary.floats(), b = try secondary.floats()
        guard a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { throw CTError.invalidTensor("voice blend values") }
        if weight == 0 { return primary }
        if weight == 1 { return secondary }
        let values = zip(a, b).map { $0 * (1 - weight) + $1 * weight }
        guard values.allSatisfy(\.isFinite) else { throw CTError.invalidTensor("voice blend overflow") }
        return try CTTensor(values, shape: primary.shape)
    }
}
