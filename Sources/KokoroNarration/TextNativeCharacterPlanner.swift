import Foundation
import KokoroPronunciation

/// Shared speaker attribution and book identities, followed by the native text
/// planner. No phonemization, acting tags, voice blending or audio processing.
enum TextNativeCharacterPlanner {
    private struct Span {
        let text: String
        let offset: Int
        let voiceID: String
        let role: DialogueTimingRole
        let speakerID: String?
    }
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
        let originalSpans = try StoryNarrator().plan(text, narratorVoiceID: cast.narratorVoiceID,
            characterVoices: cast.characterVoices, dialogue: attribution.annotations, mode: .characterVoices)
        var spans = originalSpans.map {
            Span(text: $0.text, offset: $0.offset, voiceID: $0.voiceID,
                 role: $0.role == .dialogue ? .dialogue : .narration, speakerID: $0.speakerID)
        }
        if language == "es", let structure = StageDialogueStructure.parseBook(text, languageCode: language,
            establishedDialogue: spans.filter { $0.role == .dialogue }.map {
                .init(range: NSRange(location: $0.offset, length: $0.text.utf16.count), speakerID: $0.speakerID)
            }, knownSpeakerLabels: cast.aliases),
           structure.spans.contains(where: { $0.role == .stageDirection || $0.role == .speakerLabel }) {
            spans = structure.spans.map { span in
                let dialogue = span.role == .dialogue
                let voice = dialogue ? span.speakerID.flatMap { cast.characterVoices[$0] } ?? cast.narratorVoiceID
                    : cast.narratorVoiceID
                let role: DialogueTimingRole = switch span.role {
                case .dialogue: .dialogue
                case .stageDirection, .speakerLabel: .attribution
                case .narration: .narration
                }
                return Span(text: span.text, offset: span.range.location, voiceID: voice,
                            role: role, speakerID: dialogue ? span.speakerID : nil)
            }
        }
        var fragments: [(BookNarrationUnit, Span)] = []
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
                boundaryAfter: boundary, role: span.role,
                speakerID: span.speakerID)
            unit.spokenText = local.spokenText
            unit.prosody = local.prosody
            return unit
        }
        return BookNarrationPlan(units: units, cast: cast, attribution: attribution,
                                 characterAttributionSupported: true)
    }
}
