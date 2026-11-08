import KokoroCatalog
import KokoroPronunciation

extension NarrationModel {
    /// The model owns its voice IDs. Hosts must not build a Plus cast from the
    /// Kokoro catalog or infer native voice metadata from Kokoro ID prefixes.
    public struct CharacterVoice: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let gender: BookVoiceCast.Gender
    }

    public func characterVoiceCatalog(language: String) -> [CharacterVoice] {
        guard supportsCharacterVoices, let language = NarrationLanguage.normalize(language),
              supportedLanguageCodes.contains(language) else { return [] }
        if usesTextNativePlanning {
            return nativeVoices.filter { $0.language == language }.map {
                CharacterVoice(id: $0.id, name: $0.name, gender: self == .pocket
                    ? PocketTTSCatalog.voice(id: $0.id).flatMap { BookVoiceCast.Gender(rawValue: $0.gender.rawValue) } ?? .unknown
                    : ($0.styleID.hasPrefix("F") ? .female : .male))
            }
        }
        return Voice.all.filter { $0.language.rawValue == language }.map {
            CharacterVoice(id: $0.id, name: $0.name, gender: $0.id.dropFirst().first == "f" ? .female : .male)
        }
    }

    /// Synthesis language support and automatic speaker attribution are separate.
    /// Unresolved dialogue uses the narrator; no alternating-speaker guesses.
    public func supportsAutomaticCharacterAttribution(language: String) -> Bool {
        guard supportsCharacterVoices, let language = NarrationLanguage.normalize(language) else { return false }
        return supportedLanguageCodes.contains(language) && SpeakerAttributor.supportedLanguageCodes.contains(language)
    }

    /// Persist the returned cast before playback and retain it between chapters.
    /// BookVoiceCast stores a language code independent of the phoneme catalog.
    /// Localized explicit speech tags and labels share the same persisted cast.
    public func makeVoiceCast(bookID: String, language: String, narratorVoiceID: String) throws -> BookVoiceCast {
        guard let code = NarrationLanguage.normalize(language),
              supportedLanguageCodes.contains(code) else {
            throw NarrationPipeline.PlanningError.unsupportedLanguage(language)
        }
        let voices = characterVoiceCatalog(language: code)
        guard voices.contains(where: { $0.id == narratorVoiceID }) else {
            throw NarrationPipeline.PlanningError.invalidVoice
        }
        return try BookVoiceCast(bookID: bookID, languageCode: code, narratorVoiceID: narratorVoiceID,
            voicePool: voices.map(\.id).filter { $0 != narratorVoiceID },
            voiceGenders: Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.gender) }),
            voiceSharing: .reuseCompatible)
    }

    /// Add newly available voices without changing identities, assignments or
    /// explicit narrator fallbacks. Reject a cast from a different model catalog.
    public func expandingVoiceCatalog(in cast: BookVoiceCast) throws -> BookVoiceCast {
        let voices = characterVoiceCatalog(language: cast.language.rawValue)
        let available = Set(voices.map(\.id))
        let existing = Set(cast.voicePool + [cast.narratorVoiceID] + Array(cast.characterVoices.values))
        guard existing.isSubset(of: available) else { throw NarrationPipeline.PlanningError.invalidVoice }
        return try cast.addingVoices(voices.map(\.id).filter { $0 != cast.narratorVoiceID },
            genders: Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.gender) }))
    }
}
