import Foundation
import KokoroCatalog
import LibroxCTNative
import KokoroPronunciation

/// The common entry point for book playback, preparation, exports and auditions.
/// Hosts persist the optional cast; model adapters own their input representation.
public actor NarrationPipeline {
    public static let revision = "narration-pipeline-2:native-characters-4:" + TextNativeNarrationPlanner.revision
    public struct Plan: Sendable {
        public let units: [BookNarrationUnit]
        public let narratorVoiceID: String
        public let language: String
        public let cast: BookVoiceCast?
        public let bookPlan: BookNarrationPlan?
    }
    public enum PlanningError: Error { case unsupportedLanguage(String), invalidVoice }
    private let bookPlanner = BookNarrationPlanner()
    private let pronunciation = PronunciationEngine()
    public init() {}

    public func plan(_ text: String, model: NarrationModel, bookID: String, chapterID: String,
                     narratorVoiceID: String?, language: String? = nil, metadataLanguage: String? = nil,
                     cast: BookVoiceCast? = nil, characterVoices: Bool = false,
                     options: PronunciationOptions = .init(), delivery: NarrationDeliveryOptions = .init(expressive: true),
                     lexicon: SpokenTextLexicon = .init(), nativeExpression: Bool = false, repositoryID: String? = nil,
                     pocketChunking: PocketTTSChunkingOptions = .init(),
                     pocketSampling: PocketTTSSamplingOptions = .init(),
                     pocketDelivery: PocketTTSBookDelivery = .init()) async throws -> Plan {
        try Task.checkCancellation()
        if model == .pocket { try pocketSampling.validate() }
        let delivery = model.resolvedDeliveryOptions(delivery)
        let preferredLanguage = narratorVoiceID.flatMap { id in
            model.nativeVoices.first { $0.id == id }?.language ?? Voice.named(id)?.language.rawValue
        }
        let language = NarrationLanguage.normalize(language)
            ?? NarrationLanguage.detect(metadata: metadataLanguage, sample: text) ?? preferredLanguage ?? "en"
        guard model.supportedLanguageCodes.contains(language) else { throw PlanningError.unsupportedLanguage(language) }
        guard let voiceID = model.resolvedVoiceID(narratorVoiceID, language: language) else { throw PlanningError.invalidVoice }
        var units: [BookNarrationUnit]
        let updatedCast: BookVoiceCast?
        var originalPlan: BookNarrationPlan?
        if model.usesTextNativePlanning {
            let nativeCast: BookVoiceCast?
            if let cast { nativeCast = cast }
            else if characterVoices && model.supportsAutomaticCharacterAttribution(language: language) {
                nativeCast = try model.makeVoiceCast(bookID: bookID, language: language, narratorVoiceID: voiceID)
            } else { nativeCast = nil }
            if let nativeCast {
                let plan = try TextNativeCharacterPlanner.plan(text, bookID: bookID, chapterID: chapterID,
                    language: language, cast: nativeCast, characterVoices: characterVoices, lexicon: lexicon, model: model, pocketChunking: pocketChunking)
                units = plan.units; updatedCast = plan.cast; originalPlan = plan
            } else {
                units = try TextNativeNarrationPlanner.plan(text, voiceID: voiceID, lexicon: lexicon, model: model, pocketChunking: pocketChunking)
                updatedCast = nil
            }
        } else {
            guard let phoneticLanguage = PronunciationLanguage(rawValue: language) else { throw PlanningError.unsupportedLanguage(language) }
            let original: BookVoiceCast
            if let cast { original = cast }
            else if characterVoices && model.supportsCharacterVoices {
                original = try model.makeVoiceCast(bookID: bookID, language: language, narratorVoiceID: voiceID)
            } else {
                original = try BookVoiceCast(bookID: bookID, language: phoneticLanguage,
                                            narratorVoiceID: voiceID, voicePool: [])
            }
            let plan = try await bookPlanner.plan(text, chapterID: chapterID, cast: original,
                characterVoices: characterVoices && model.supportsCharacterVoices,
                options: options, profile: model.deliveryProfile, delivery: delivery)
            units = plan.units; updatedCast = plan.cast
            originalPlan = plan
            for index in units.indices {
                let reading = lexicon.applyingReadings(to: units[index].text, language: language)
                if reading != units[index].text {
                    let prepared = try pronunciation.phonemize(reading, language: phoneticLanguage, options: options)
                    units[index].spokenText = reading
                    units[index].phonemes = prepared.phonemes
                    units[index].pronunciationDiagnostics += prepared.diagnostics
                    // Old phone offsets cannot describe the substituted reading.
                    units[index].expressiveFocus = []
                }
            }
        }
        for index in units.indices where units[index].prosody == nil {
            units[index].prosody = NarrationProsody.analyze(text: units[index].text, languageCode: language)
        }
        if model == .plus, nativeExpression || repositoryID == CTApprovedExpression.installationIdentity,
           !delivery.blendedVoice {
            units = try NarrationNativeExpression.prepare(units: units, source: text,
                decisions: originalPlan?.attribution?.decisions ?? [])
        }
        if model == .pocket {
            for index in units.indices { units[index].pocketSampling = pocketSampling }
            units = try pocketDelivery.applying(to: units)
        }
        return Plan(units: units, narratorVoiceID: updatedCast?.narratorVoiceID ?? voiceID,
                    language: language, cast: updatedCast,
                    bookPlan: originalPlan.map { BookNarrationPlan(units: units, cast: $0.cast,
                        attribution: $0.attribution, characterAttributionSupported: $0.characterAttributionSupported) })
    }
}
