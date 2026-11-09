import KokoroCatalog

/// Initial settings for a new Max book. Persist the resolved fields with the book;
/// never reapply a changing default over the reader's saved choices.
public struct PocketTTSNarratorPreset: Sendable {
    public let voiceID: String
    public var delivery: PocketTTSBookDelivery { .init(narratorStyle: .calm) }
    public var chunking: PocketTTSChunkingOptions { .carefulReading }
    public var sampling: PocketTTSSamplingOptions { .init(temperature: 0.3, samplerSteps: 4) }

    /// Caro Davy / Calm, matching the approved English book-scene audition.
    /// Other languages use their own exported state and remain listening previews.
    public static func defaultNarrator(language: String) throws -> Self {
        guard let language = NarrationLanguage.normalize(language),
              let name = PocketTTSCatalog.defaultVoices[language] else {
            throw NarrationPipeline.PlanningError.unsupportedLanguage(language)
        }
        return Self(voiceID: "pocket-\(name)-\(language)-v1")
    }
}
