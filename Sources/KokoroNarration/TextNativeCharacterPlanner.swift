import Foundation
import KokoroPronunciation

/// Shared speaker attribution and book identities, followed by the native text
/// planner. No phonemization, acting tags, voice blending or audio processing.
enum TextNativeCharacterPlanner {
    static func plan(_ text: String, bookID: String, chapterID: String, language: String,
                     cast original: BookVoiceCast, characterVoices: Bool,
                     lexicon: SpokenTextLexicon) throws -> BookNarrationPlan {
        _ = try original.encoded()
        guard original.bookID == bookID else { throw BookVoiceCast.CastError.wrongBook }
        guard original.language.rawValue == language else { throw BookNarrationPlanner.PlanningError.languageMismatch }
        let catalog = Set(NarrationModel.plus.characterVoiceCatalog(language: language).map(\.id))
        let requested = Set(original.voicePool + [original.narratorVoiceID] + Array(original.characterVoices.values))
        guard requested.isSubset(of: catalog) else { throw NarrationPipeline.PlanningError.invalidVoice }
        let supported = NarrationModel.plus.supportsAutomaticCharacterAttribution(language: language)
        guard characterVoices && supported else {
            return BookNarrationPlan(units: try TextNativeNarrationPlanner.plan(text,
                voiceID: original.narratorVoiceID, lexicon: lexicon), cast: original,
                attribution: nil, characterAttributionSupported: supported)
        }

        var cast = original
        let attribution = try SpeakerAttributor().analyze(text, bookID: bookID, chapterID: chapterID, cast: &cast)
        let spans = try StoryNarrator().plan(text, narratorVoiceID: cast.narratorVoiceID,
            characterVoices: cast.characterVoices, dialogue: attribution.annotations, mode: .characterVoices)
        var fragments: [(BookNarrationUnit, StoryReadingSpan)] = []
        for span in spans {
            try Task.checkCancellation()
            for unit in try TextNativeNarrationPlanner.plan(span.text, voiceID: span.voiceID, lexicon: lexicon) {
                fragments.append((unit, span))
            }
        }
        let source = text as NSString
        let units = fragments.enumerated().map { index, fragment in
            let (local, span) = fragment
            let range = NSRange(location: span.offset + local.range.location, length: local.range.length)
            let next = index + 1 < fragments.count
                ? fragments[index + 1].1.offset + fragments[index + 1].0.range.location : source.length
            let gap = source.substring(with: NSRange(location: NSMaxRange(range), length: next - NSMaxRange(range)))
            let boundary: NarrationBoundary = gap.contains(where: \.isNewline) ? .paragraph : local.boundaryAfter
            var unit = BookNarrationUnit(sourceText: local.text, sourceRange: range, narratorID: span.voiceID,
                boundaryAfter: boundary, role: span.role == .dialogue ? .dialogue : .narration,
                speakerID: span.speakerID)
            unit.spokenText = local.spokenText
            unit.prosody = local.prosody
            return unit
        }
        return BookNarrationPlan(units: units, cast: cast, attribution: attribution,
                                 characterAttributionSupported: true)
    }
}
