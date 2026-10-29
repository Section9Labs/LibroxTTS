import Foundation
import NaturalLanguage
import KokoroNarration
import KokoroPronunciation

public struct ChatterboxDirectedUnit: Sendable {
    public let request: ChatterboxRequest
    public let timingContext: DialogueTimingContext
    public let performance: NarrationPerformance
    /// Original UTF-16 ranges of the component sentence fragments. Audio offsets
    /// are deliberately absent: the model provides no validated sentence aligner.
    public var sourceFragments: [NSRange] = []
}

/// Text-native orchestration using Librox's source/cast, performance and timing
/// contracts. Delivery names remain descriptive evidence, not exact model switches.
public enum ChatterboxBookDirector {
    public static let revision = "librox-chatterbox-director-2"
    public enum Direction: Sendable { case neutral, storyteller }
    public enum Grouping: Sendable, Equatable {
        case sentences
        /// Narration only; dialogue, paragraph and performance changes remain boundaries.
        case compatibleNarration(maxCharacters: Int = 300)
        public var cacheRevision: String {
            switch self {
            case .sentences: "sentences-1"
            case .compatibleNarration(let maximum): "compatible-narration-1:\(maximum)"
            }
        }
    }
    public enum PlanningError: Error { case unbreakableUnit, tooManyUnits, invalidGroupingBudget }

    public static func plan(_ source: String, language: String, narratorID: String,
                            conditioningFiles: [String: URL], direction: Direction = .storyteller,
                            grouping: Grouping = .sentences,
                            reviewedDialogue: [DialogueAnnotation]? = nil,
                            characterVoices: [String: String] = [:], seed: UInt64? = nil) throws -> [ChatterboxDirectedUnit] {
        guard ["en", "es"].contains(language) else { throw ChatterboxNarrationError.unsupportedLanguage(language) }
        let characterBudget: Int
        switch grouping {
        case .sentences: characterBudget = 300
        case .compatibleNarration(let maximum):
            guard (50...300).contains(maximum) else { throw PlanningError.invalidGroupingBudget }
            characterBudget = maximum
        }
        let story = StoryNarrator()
        // Unreviewed quotes supply possible delivery boundaries only. They never
        // identify a character or alternate model voices.
        let annotations = try reviewedDialogue ?? story.quotedCandidates(in: source)
        let spans = try story.plan(source, narratorVoiceID: narratorID, characterVoices: characterVoices,
            dialogue: annotations, mode: reviewedDialogue == nil ? .singleNarrator : .characterVoices)
        let original = source as NSString
        var result: [ChatterboxDirectedUnit] = []
        var previous: BookNarrationUnit?
        for span in spans {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.setLanguage(NLLanguage(rawValue: language)); tokenizer.string = span.text
            let sentences = tokenizer.tokens(for: span.text.startIndex..<span.text.endIndex)
            let cuts = [span.text.startIndex] + sentences.dropFirst().map(\.lowerBound) + [span.text.endIndex]
            let spanEnd = span.offset + span.length
            let following = span.role == .dialogue
                ? String(original.substring(from: spanEnd).prefix(NarrationPerformance.maximumAttributionUTF16)) : ""
            for index in 0..<(cuts.count - 1) {
                var remaining = cuts[index]..<cuts[index + 1]
                while !remaining.isEmpty {
                    var end = span.text.index(remaining.lowerBound, offsetBy: characterBudget, limitedBy: remaining.upperBound) ?? remaining.upperBound
                    if end < remaining.upperBound {
                        guard let space = span.text[remaining.lowerBound..<end].lastIndex(where: \.isWhitespace), space > remaining.lowerBound
                        else { throw PlanningError.unbreakableUnit }
                        end = span.text.index(after: space)
                    }
                    var lower = remaining.lowerBound, upper = end
                    while lower < upper, span.text[lower].isWhitespace { lower = span.text.index(after: lower) }
                    while upper > lower, span.text[span.text.index(before: upper)].isWhitespace { upper = span.text.index(before: upper) }
                    remaining = end..<remaining.upperBound
                    guard lower < upper else { continue }
                    let local = NSRange(lower..<upper, in: span.text)
                    let range = NSRange(location: span.offset + local.location, length: local.length)
                    let text = original.substring(with: range)
                    let role: DialogueTimingRole = span.role == .dialogue ? .dialogue : .narration
                    let unit = BookNarrationUnit(sourceText: text, sourceRange: range, narratorID: span.voiceID,
                        role: role, speakerID: span.speakerID)
                    let base = try ChatterboxNarrationBridge.prepare(unit, source: source, followingAttribution: following,
                        languageCode: language, conditioningFiles: conditioningFiles, seed: seed)
                    let performance = base.sourceContext!.performance
                    let exaggeration = direction == .neutral ? Float(0.5) : intensity(performance)
                    let request = try ChatterboxRequest(text: base.text, language: language, conditioningFile: base.conditioningFile,
                        exaggeration: exaggeration, guidance: exaggeration >= 0.85 ? 0.25 : 0.3,
                        temperature: base.temperature, maxTokens: base.maxTokens, seed: seed, sourceContext: base.sourceContext)
                    let gap = previous.map { original.substring(with: NSRange(location: NSMaxRange($0.range),
                        length: range.location - NSMaxRange($0.range))) } ?? ""
                    let context = DialogueTimingContext(previousText: previous?.text ?? "", nextText: text,
                        previousSpeakerID: previous?.speakerID, nextSpeakerID: unit.speakerID,
                        previousRole: previous?.role ?? .unknown, nextRole: role,
                        structuralBreak: gap.contains(where: \.isNewline) ? .paragraph : .none,
                        sourceGap: gap, languageCode: language)
                    let candidate = ChatterboxDirectedUnit(request: request, timingContext: context,
                        performance: performance, sourceFragments: [range])
                    if case .compatibleNarration = grouping, let last = result.last,
                       let merged = try merged(last, candidate, source: original, maximum: characterBudget) {
                        result[result.count - 1] = merged
                    } else { result.append(candidate) }
                    guard result.count <= 128 else { throw PlanningError.tooManyUnits }
                    previous = unit
                }
            }
        }
        return result
    }

    private static func merged(_ left: ChatterboxDirectedUnit, _ right: ChatterboxDirectedUnit,
                               source: NSString, maximum: Int) throws -> ChatterboxDirectedUnit? {
        let a = left.request, b = right.request
        guard left.timingContext.nextRole == .narration, right.timingContext.nextRole == .narration,
              right.timingContext.structuralBreak == .none,
              left.performance == right.performance,
              a.language == b.language, a.conditioningFile == b.conditioningFile,
              a.exaggeration == b.exaggeration, a.guidance == b.guidance,
              a.temperature == b.temperature, a.maxTokens == b.maxTokens, a.seed == b.seed,
              let ac = a.sourceContext, let bc = b.sourceContext,
              ac.voiceID == bc.voiceID, ac.speakerID == bc.speakerID,
              NSMaxRange(ac.range) <= bc.range.location else { return nil }
        let gap = source.substring(with: NSRange(location: NSMaxRange(ac.range),
                                                 length: bc.range.location - NSMaxRange(ac.range)))
        guard gap.allSatisfy(\.isWhitespace), !gap.contains(where: \.isNewline) else { return nil }
        let range = NSRange(location: ac.range.location, length: NSMaxRange(bc.range) - ac.range.location)
        let text = source.substring(with: range)
        guard text.count <= maximum else { return nil }
        let context = ChatterboxSourceContext(range: range, originalText: text, voiceID: ac.voiceID,
            speakerID: ac.speakerID, performance: left.performance)
        let request = try ChatterboxRequest(text: text, language: a.language, conditioningFile: a.conditioningFile,
            exaggeration: a.exaggeration, guidance: a.guidance, temperature: a.temperature,
            maxTokens: a.maxTokens, seed: a.seed, sourceContext: context)
        return .init(request: request, timingContext: left.timingContext, performance: left.performance,
                     sourceFragments: left.sourceFragments + right.sourceFragments)
    }

    private static func intensity(_ value: NarrationPerformance) -> Float {
        switch value.delivery {
        case .whisper, .soft, .tender: return 0.4
        case .shout: return 1
        case .urgent: return 0.9
        case .cheerful, .playful: return 0.85
        case .solemn, .weary, .hesitant: return 0.45
        case .firm: return 0.7
        case .neutral: break
        }
        switch value.mood.mood {
        case .angry, .joyful, .fearful: return 0.85
        case .sad, .relieved: return 0.45
        case .neutral: break
        }
        switch value.speechAct.act {
        case .urgentCommand, .surprise: return 0.85
        case .hesitation, .reassurance: return 0.45
        default: return 0.55
        }
    }
}
