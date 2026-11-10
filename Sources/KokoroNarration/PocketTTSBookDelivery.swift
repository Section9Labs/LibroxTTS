import Foundation
import KokoroCatalog

/// Persist with the book and its BookVoiceCast. Character keys are stable cast
/// speaker IDs, not display names or voice IDs. No automatic emotion inference.
public struct PocketTTSBookDelivery: Codable, Hashable, Sendable {
    public var narratorStyle: PocketTTSDeliveryStyle
    public var characterStyles: [String: PocketTTSDeliveryStyle]

    public init(narratorStyle: PocketTTSDeliveryStyle = .original,
                characterStyles: [String: PocketTTSDeliveryStyle] = [:]) {
        self.narratorStyle = narratorStyle
        self.characterStyles = characterStyles
    }

    /// Include in chapter-plan/preparation identities. Length-prefixed speaker
    /// keys preserve arbitrary Unicode IDs without separator collisions.
    public var cacheIdentity: String {
        let assignments = characterStyles.keys.sorted().map { key in
            "\(key.utf8.count):\(key)=\(characterStyles[key]!.cacheIdentity)"
        }.joined(separator: "|")
        return "pocket-book-delivery-1:\(narratorStyle.cacheIdentity):\(assignments)"
    }

    /// Unattributed dialogue stays Original; narrator styling never leaks into
    /// dialogue. Narration, speaker labels and attribution use narrator delivery.
    /// A voice without exported styles (Original only) always reads Original.
    public func style(for unit: BookNarrationUnit) -> PocketTTSDeliveryStyle {
        let requested = unit.role == .dialogue
            ? unit.speakerID.flatMap { characterStyles[$0] } ?? .original : narratorStyle
        return PocketTTSDeliveryCatalog.resolvedStyle(requested, voiceID: unit.voiceID)
    }

    public func applying(to units: [BookNarrationUnit]) throws -> [BookNarrationUnit] {
        try units.map { unit in
            try Task.checkCancellation()
            let style = style(for: unit)
            _ = try PocketTTSDeliveryCatalog.stateName(voiceID: unit.voiceID, style: style)
            var result = unit
            result.pocketDeliveryStyle = style == .original ? nil : style
            return result
        }
    }
}
