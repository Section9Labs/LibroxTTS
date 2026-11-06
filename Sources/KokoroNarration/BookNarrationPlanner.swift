// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import NaturalLanguage
import KokoroCatalog
import KokoroPronunciation

/// One bounded synthesis unit. Offsets and text refer to the original source;
/// pronunciation is separate so a host never has to rewrite the displayed book.
public struct BookNarrationUnit: Sendable {
    public let text: String
    public let range: NSRange
    public let voiceID: String
    public let phonemes: String
    public let boundaryAfter: NarrationBoundary
    public var expression: NarrationExpression = .neutral
    /// Present for the opt-in source-context plan. Does not select a render rate.
    public var prosody: NarrationProsody? = nil
    public var speakerID: String? = nil
    public var role: DialogueTimingRole = .unknown
    public var speechAct: NarrationActEvidence? = nil
    public var expressiveFocus: [NarrationFocus] = []
    /// Hosts can surface spelling fallbacks and unsupported sounds rather than
    /// treating successful token generation as pronunciation acceptance.
    /// Diagnostic offsets, where present, are local to this unit's text.
    public var pronunciationDiagnostics: [PronunciationDiagnostic] = []
    public var requiresRendererSplit: Bool { phonemes.unicodeScalars.count > 510 }
}

public struct BookNarrationPlan: Sendable {
    public let units: [BookNarrationUnit]
    /// Persist atomically before playing the first newly assigned voice.
    public let cast: BookVoiceCast
    public let attribution: ChapterAttribution?
    public let characterAttributionSupported: Bool
}

/// Baseline retains the existing chunking and duration-label behavior. The
/// candidate keeps source context and supplies native punctuation at caller speed.
public enum BookNarrationProsody: String, Sendable {
    case baseline, sourceContext, conversationContext, structuredConversation

    /// Include with voice, options, source and renderer revision in prepared-audio
    /// cache keys. Opting into context must not reuse baseline audio silently.
    public var cacheRevision: String {
        let grouping = switch self {
        case .baseline: "book-narration-1"
        case .sourceContext: "book-source-context-1"
        case .conversationContext: "book-conversation-context-2"
        case .structuredConversation: "book-structured-conversation-1"
        }
        return grouping + ":" + PronunciationEngine.pipelineRevision
    }
}

/// Optional audiobook orchestration with no model, audio session or file-system
/// ownership. Feed bounded chapter excerpts in source order and retain the
/// returned cast. Actors serialize mutable pronunciation state across calls.
public actor BookNarrationPlanner {
    public enum PlanningError: Error { case invalidVoice, languageMismatch, unbreakableUnit }
    public static let pipelineVersion = "book-narration-2:" + PronunciationEngine.pipelineRevision
    private let pronunciation = PronunciationEngine()
    private let planner = NarrationPlanner()
    public init() {}

    public func plan(_ text: String, chapterID: String, cast original: BookVoiceCast,
                     characterVoices: Bool = false, targetPhonemes: Int = 240,
                     options: PronunciationOptions? = nil,
                     expressiveDelivery: Bool = false,
                     prosody: BookNarrationProsody = .baseline,
                     profile: NarrationProfile? = nil,
                     delivery: NarrationDeliveryOptions = .init()) throws -> BookNarrationPlan {
        let prosody = profile?.prosody ?? prosody
        let targetPhonemes = profile?.targetPhonemes ?? targetPhonemes
        guard text.unicodeScalars.count <= PronunciationEngine.maximumInputScalars else {
            throw PronunciationError.inputTooLong(limit: PronunciationEngine.maximumInputScalars)
        }
        // Validate even single-narrator calls, including serialized state supplied
        // by an untrusted book/cache. Character and narrator voices must agree.
        _ = try original.encoded()
        for id in Set(original.voicePool + [original.narratorVoiceID] + Array(original.characterVoices.values)) {
            guard let voice = Voice.named(id) else { throw PlanningError.invalidVoice }
            guard voice.language.rawValue == original.language.rawValue else { throw PlanningError.languageMismatch }
        }
        var cast = original
        let conversation = prosody == .conversationContext || prosody == .structuredConversation
        let supportsAttribution = cast.language == .english || cast.language == .spanish
        let attribution: ChapterAttribution?
        if (characterVoices || conversation) && supportsAttribution {
            attribution = try SpeakerAttributor().analyze(text, bookID: cast.bookID, chapterID: chapterID, cast: &cast)
        } else { attribution = nil }
        let narrator = StoryNarrator()
        var dialogue = attribution?.annotations ?? []
        if conversation {
            // Knowing who speaks does not require allocating another voice.
            // Preserve more precise existing annotations when tags split a turn.
            for decision in attribution?.decisions ?? [] {
                guard let speakerID = decision.speakerID else { continue }
                let range = NSRange(location: decision.offset, length: decision.length)
                if !dialogue.contains(where: {
                    NSIntersectionRange(range, NSRange(location: $0.offset, length: $0.length)).length > 0
                }) {
                    dialogue.append(.init(offset: decision.offset, length: decision.length, speakerID: speakerID))
                }
            }
        }
        if expressiveDelivery || conversation {
            // Delivery does not require a known character or an available voice.
            // Preserve assigned spans; unresolved dialogue keeps the narrator.
            for candidate in try narrator.quotedCandidates(in: text) {
                let range = NSRange(location: candidate.offset, length: candidate.length)
                if !dialogue.contains(where: {
                    NSIntersectionRange(range, NSRange(location: $0.offset, length: $0.length)).length > 0
                }) { dialogue.append(candidate) }
            }
            // Spanish books commonly use dialogue dashes rather than quotes.
            // Only an explicit delivery tag qualifies here; ordinary dash-led
            // prose and uncertain attribution remain unchanged.
            if cast.language == .spanish {
                let source = text as NSString
                let pattern = #"(?m)^[ \t]*—[^\r\n—]+(?=—[ \t]*(?:susurró|murmuró|musitó|gritó|exclamó|dijo|respondió|replicó|preguntó)\b)"#
                for match in try NSRegularExpression(pattern: pattern).matches(
                    in: text, range: NSRange(location: 0, length: source.length)) {
                    let end = NSMaxRange(match.range)
                    let following = source.substring(with: NSRange(location: end, length: min(96, source.length - end)))
                    guard NarrationExpression.infer(dialogue: source.substring(with: match.range),
                        followingAttribution: following, voiceID: cast.narratorVoiceID) != .neutral else { continue }
                    if !dialogue.contains(where: {
                        NSIntersectionRange(match.range, NSRange(location: $0.offset, length: $0.length)).length > 0
                    }) {
                        dialogue.append(.init(offset: match.range.location, length: match.range.length))
                    }
                }
            }
        }
        if conversation, cast.language == .spanish {
            // Spanish fiction commonly starts each spoken turn with an em dash.
            // Preserve the whole written line (including its inline reporting tag)
            // rather than treating a normal hyphen/bullet as dialogue.
            let source = text as NSString
            let pattern = #"(?m)^[ \t]*—[^\r\n]+"#
            for match in try NSRegularExpression(pattern: pattern).matches(in: text,
                range: NSRange(location: 0, length: source.length)) {
                if !dialogue.contains(where: {
                    NSIntersectionRange(match.range, NSRange(location: $0.offset, length: $0.length)).length > 0
                }) { dialogue.append(.init(offset: match.range.location, length: match.range.length)) }
            }
        }
        let spans = try narrator.plan(text, narratorVoiceID: cast.narratorVoiceID,
            characterVoices: cast.characterVoices, dialogue: dialogue,
            mode: characterVoices ? .characterVoices : .singleNarrator)
        var units: [BookNarrationUnit] = []
        let mergedSpans = renderingSpans(spans,
            policy: prosody == .structuredConversation ? .conversationContext : prosody,
            languageCode: cast.language.rawValue)
        let preparedSpans = prosody == .structuredConversation && cast.language == .spanish
            ? structuredSpans(mergedSpans, source: text, cast: cast, characterVoices: characterVoices)
            : mergedSpans
        for span in preparedSpans {
            try Task.checkCancellation()
            if prosody != .baseline, span.text.allSatisfy(\.isWhitespace) {
                // A voice/identity boundary can leave a paragraph separator in
                // its own span. Preserve its source range but never synthesize it.
                var separator = BookNarrationUnit(text: span.text,
                    range: NSRange(location: span.offset, length: span.text.utf16.count),
                    voiceID: span.voiceID, phonemes: "",
                    boundaryAfter: span.text.contains(where: \.isNewline) ? .paragraph : .continuation)
                separator.prosody = NarrationProsody.analyze(text: span.text, voiceID: span.voiceID)
                units.append(separator)
                continue
            }
            let options = options ?? PronunciationOptions(britishEnglish: Voice.named(span.voiceID)?.isBritish ?? false)
            var offset = span.offset
            let passages = conversation && span.isDialogue
                ? expressionPassages(span.text, voiceID: span.voiceID) : [span.text]
            let planned = try passages.flatMap {
                try planner.plan($0, language: cast.language, options: options, targetPhonemes: targetPhonemes)
            }
            for unit in planned {
                let source = text as NSString
                let end = span.offset + span.text.utf16.count
                let following = span.isDialogue
                    ? source.substring(with: NSRange(location: end, length: min(192, source.length - end))) : ""
                let fragments: [PreparedFragment]
                if prosody != .baseline {
                    fragments = try sourceContextFragments(unit.text, language: cast.language, options: options,
                        voiceID: span.voiceID, followingAttribution: following)
                } else {
                    let result = try pronunciation.phonemize(unit.text, language: cast.language, options: options)
                    fragments = [.init(text: unit.text, phonemes: result.phonemes, prosody: nil,
                                       diagnostics: result.diagnostics)]
                }
                for (index, fragment) in fragments.enumerated() {
                    var renderedUnit = BookNarrationUnit(text: fragment.text,
                        range: NSRange(location: offset, length: fragment.text.utf16.count),
                        voiceID: span.voiceID, phonemes: fragment.phonemes,
                        boundaryAfter: index == fragments.count - 1 ? unit.boundaryAfter : .continuation)
                    renderedUnit.prosody = fragment.prosody
                    renderedUnit.pronunciationDiagnostics = fragment.diagnostics
                    renderedUnit.speakerID = span.speakerID
                    renderedUnit.role = span.timingRole ?? (span.isDialogue ? .dialogue : .narration)
                    if conversation, span.isDialogue {
                        renderedUnit.speechAct = NarrationExpressionLexicon.analyze(text: fragment.text, voiceID: span.voiceID)
                    }
                    // The candidate carries source evidence separately; it must
                    // not also inherit the legacy global duration multipliers.
                    if prosody == .baseline, expressiveDelivery, span.isDialogue {
                        renderedUnit.expression = NarrationExpression.infer(dialogue: fragment.text,
                            followingAttribution: following, voiceID: span.voiceID)
                    }
                    units.append(renderedUnit)
                    offset += fragment.text.utf16.count
                }
            }
        }
        var prepared = profile?.prepare(units) ?? units
        if profile == .enhanced, delivery.expressive {
            for i in prepared.indices where !prepared[i].phonemes.isEmpty {
                prepared[i].expressiveFocus = try NarrationExpressiveDelivery.focus(
                    text: prepared[i].text, sourceRange: prepared[i].range, phonemes: prepared[i].phonemes,
                    source: text, language: cast.language,
                    options: options ?? .init(britishEnglish: Voice.named(prepared[i].voiceID)?.isBritish ?? false))
            }
        }
        return .init(units: prepared, cast: cast, attribution: attribution, characterAttributionSupported: supportsAttribution)
    }

    private struct RenderingSpan {
        var text: String
        let offset: Int
        let voiceID: String
        var speakerID: String?
        var isDialogue: Bool
        var timingRole: DialogueTimingRole? = nil
    }

    /// Preserve every source character while keeping explicit stage directions
    /// in the narrator's voice. Unknown printed labels are timing identities,
    /// not permission to allocate or replace a saved character voice.
    private func structuredSpans(_ spans: [RenderingSpan], source: String,
                                 cast: BookVoiceCast, characterVoices: Bool) -> [RenderingSpan] {
        var seeds = spans.filter(\.isDialogue).map {
            StageDialogueRange(range: NSRange(location: $0.offset, length: $0.text.utf16.count),
                               speakerID: $0.speakerID)
        }
        // An embedded quote must not hide the enclosing em-dash dialogue turn.
        // Retain precise seeds when they identify distinct embedded speakers.
        if let turns = try? NSRegularExpression(pattern: #"(?m)^[ \t]*—[^\r\n]+"#) {
            for match in turns.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)) {
                let overlapping = seeds.filter { NSIntersectionRange($0.range, match.range).length > 0 }
                let identities = Set(overlapping.compactMap(\.speakerID))
                guard identities.count <= 1,
                      overlapping.allSatisfy({ $0.range.location >= match.range.location && NSMaxRange($0.range) <= NSMaxRange(match.range) }) else { continue }
                seeds.removeAll { NSIntersectionRange($0.range, match.range).length > 0 }
                seeds.append(.init(range: match.range, speakerID: identities.first))
            }
        }
        let structure = StageDialogueStructure.parse(source, languageCode: cast.language.rawValue,
            establishedDialogue: seeds, knownSpeakerLabels: cast.aliases)
        guard structure.accepted, structure.spans.map(\.text).joined() == source else { return spans }
        let original = source as NSString
        var expectedOffset = 0
        for span in structure.spans {
            guard span.range.location == expectedOffset, span.range.length >= 0,
                  span.range.length <= original.length - expectedOffset,
                  original.substring(with: span.range) == span.text else { return spans }
            expectedOffset += span.range.length
        }
        guard expectedOffset == original.length else { return spans }
        return structure.spans.map { span in
            let dialogue = span.role == .dialogue
            let voice = dialogue && characterVoices
                ? span.speakerID.flatMap { cast.characterVoices[$0] } ?? cast.narratorVoiceID
                : cast.narratorVoiceID
            let role: DialogueTimingRole = switch span.role {
            case .dialogue: .dialogue
            case .stageDirection, .speakerLabel: .attribution
            case .narration: .narration
            }
            return RenderingSpan(text: span.text, offset: span.range.location, voiceID: voice,
                speakerID: dialogue ? span.speakerID : nil, isDialogue: dialogue, timingRole: role)
        }
    }

    private func renderingSpans(_ spans: [StoryReadingSpan], policy: BookNarrationProsody,
                                languageCode: String) -> [RenderingSpan] {
        var result: [RenderingSpan] = []
        for span in spans {
            // Known speakers remain separate even when a small cast reuses the
            // same voice. Unassigned quotes can retain their narrative setup.
            if policy == .conversationContext, let previous = result.last,
               previous.voiceID == span.voiceID,
               previous.offset + previous.text.utf16.count == span.offset {
                let whitespace = span.text.allSatisfy(\.isWhitespace)
                let structural: DialogueStructuralBreak = previous.text.last?.isNewline == true ? .paragraph : .none
                let decision = DialogueTiming.classify(.init(previousText: previous.text, nextText: span.text,
                    previousSpeakerID: previous.speakerID, nextSpeakerID: span.speakerID,
                    previousRole: previous.isDialogue ? .dialogue : .narration,
                    nextRole: span.role == .dialogue ? .dialogue : .narration,
                    structuralBreak: structural, languageCode: languageCode))
                let sameSpeaker = previous.speakerID != nil && previous.speakerID == span.speakerID
                let reportingText = previous.isDialogue ? span.text : previous.text
                let shortAttribution = decision.kind == .attribution && isSingleReportingClause(reportingText)
                if whitespace || (structural == .none && (shortAttribution || sameSpeaker)) {
                    result[result.count - 1].text += span.text
                    if !whitespace {
                        result[result.count - 1].isDialogue = previous.isDialogue || span.role == .dialogue
                        result[result.count - 1].speakerID = previous.speakerID ?? span.speakerID
                    }
                    // A local attribution belongs to its utterance's context;
                    // it does not become an independent narrator turn.
                    continue
                }
            }
            if policy == .sourceContext, let previous = result.last,
               previous.voiceID == span.voiceID, previous.speakerID == span.speakerID,
               previous.offset + previous.text.utf16.count == span.offset {
                result[result.count - 1].text += span.text
                result[result.count - 1].isDialogue = previous.isDialogue && span.role == .dialogue
            } else {
                result.append(.init(text: span.text, offset: span.offset, voiceID: span.voiceID,
                                    speakerID: span.speakerID, isDialogue: span.role == .dialogue))
            }
        }
        return result
    }

    private func isSingleReportingClause(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= 128 else { return false }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        return tokenizer.tokens(for: trimmed.startIndex..<trimmed.endIndex).count <= 1
    }

    private struct PreparedFragment {
        let text: String
        let phonemes: String
        let prosody: NarrationProsody?
        let diagnostics: [PronunciationDiagnostic]
        var fits: Bool {
            phonemes.unicodeScalars.count <= 510 && text.unicodeScalars.count <= NarrationProsody.maximumTextScalars
        }
    }

    /// Candidate only: a recognized complete short expression can have its own
    /// model duration/pitch prediction. Preserve every source character and never
    /// invent punctuation or split a word. Ordinary clauses remain contextual.
    private func expressionPassages(_ text: String, voiceID: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var cuts: Set<String.Index> = [text.startIndex, text.endIndex]
        let ranges = Array(tokenizer.tokens(for: text.startIndex..<text.endIndex).prefix(64))
        var previousIsAct = false
        for range in ranges {
            let isAct = NarrationExpressionLexicon.analyze(text: String(text[range]), voiceID: voiceID).prefersStandaloneUnit
            if isAct || previousIsAct { cuts.insert(range.lowerBound) }
            previousIsAct = isAct
        }
        let sorted = cuts.sorted()
        var pieces: [String] = []
        var leading = ""
        for (start, end) in zip(sorted, sorted.dropFirst()) {
            let piece = String(text[start..<end])
            if piece.allSatisfy(\.isWhitespace) {
                if pieces.isEmpty { leading += piece } else { pieces[pieces.count - 1] += piece }
            } else {
                pieces.append(leading + piece)
                leading = ""
            }
        }
        if !leading.isEmpty { pieces.append(leading) }
        return pieces
    }

    private func sourceContextFragments(_ text: String, language: PronunciationLanguage,
                                        options: PronunciationOptions, voiceID: String,
                                        followingAttribution: String) throws -> [PreparedFragment] {
        func prepare(_ fragment: String, isFinal: Bool) throws -> PreparedFragment {
            let analysis = NarrationProsody.analyze(text: fragment,
                followingAttribution: isFinal ? followingAttribution : "", voiceID: voiceID)
            let result = try pronunciation.phonemize(fragment, language: language, options: options)
            // First compute the repaired candidate with room for its punctuation;
            // test the real 510-token limit afterwards. Never drop a sound to fit.
            let phones = analysis.preservingTerminalPunctuation(in: result.phonemes,
                                                               maximumScalars: NarrationProsody.maximumTextScalars)
            return .init(text: fragment, phonemes: phones, prosody: analysis, diagnostics: result.diagnostics)
        }
        let whole = try prepare(text, isFinal: true)
        if whole.fits { return [whole] }
        var remaining = text
        var result: [PreparedFragment] = []
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let tail = try prepare(remaining, isFinal: true)
            if tail.fits { result.append(tail); break }
            // Prefer clause boundaries, then word boundaries. CJK has no required
            // spaces, so a character boundary is its bounded last resort. Latin
            // words are never cut into newly pronounced fragments.
            var cuts: [String.Index] = []
            var clauseCuts = Set<String.Index>()
            for index in remaining.indices {
                let character = remaining[index]
                let end = remaining.index(after: index)
                let clause = ",;:—–，、；：".contains(character)
                if clause { clauseCuts.insert(end) }
                if character.isWhitespace || clause || language == .japanese || language == .chinese {
                    cuts.append(end)
                }
            }
            cuts.removeAll { $0 == remaining.endIndex }
            guard !cuts.isEmpty else { throw PlanningError.unbreakableUnit }
            var low = 0, high = cuts.count - 1
            var chosen: (index: Int, fragment: PreparedFragment)?
            while low <= high {
                let middle = low + (high - low) / 2
                let candidate = try prepare(String(remaining[..<cuts[middle]]), isFinal: false)
                if candidate.fits {
                    chosen = (middle, candidate); low = middle + 1
                } else { high = middle - 1 }
            }
            guard var chosen else { throw PlanningError.unbreakableUnit }
            // A nearby clause ending is preferable to filling every final token.
            // Only retain a substantial phrase, not a tiny isolated question.
            for index in (0...chosen.index).reversed() where clauseCuts.contains(cuts[index]) {
                let candidate = try prepare(String(remaining[..<cuts[index]]), isFinal: false)
                if candidate.fits, candidate.phonemes.unicodeScalars.count >= 320 {
                    chosen = (index, candidate)
                }
                break
            }
            guard !chosen.fragment.text.isEmpty else { throw PlanningError.unbreakableUnit }
            result.append(chosen.fragment)
            remaining = String(remaining[cuts[chosen.index]...])
        }
        return result
    }
}
