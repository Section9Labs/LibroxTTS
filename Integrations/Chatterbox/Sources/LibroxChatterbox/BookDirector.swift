import Foundation
import NaturalLanguage
import KokoroNarration
import KokoroPronunciation

public struct ChatterboxDirectedUnit: Sendable {
    public let request: ChatterboxRequest
    public let timingContext: DialogueTimingContext
    public let performance: NarrationPerformance
}

/// Text-native orchestration using Librox's source/cast, performance and timing
/// contracts. Delivery names remain descriptive evidence, not exact model switches.
public enum ChatterboxBookDirector {
    public static let revision = "librox-chatterbox-director-1"
    public enum Direction: Sendable { case neutral, storyteller }
    public enum PlanningError: Error { case unbreakableUnit, tooManyUnits }

    public static func plan(_ source: String, language: String, narratorID: String,
                            conditioningFiles: [String: URL], direction: Direction = .storyteller,
                            reviewedDialogue: [DialogueAnnotation]? = nil,
                            characterVoices: [String: String] = [:], seed: UInt64? = nil) throws -> [ChatterboxDirectedUnit] {
        guard ["en", "es"].contains(language) else { throw ChatterboxNarrationError.unsupportedLanguage(language) }
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
                    var end = span.text.index(remaining.lowerBound, offsetBy: 300, limitedBy: remaining.upperBound) ?? remaining.upperBound
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
                    result.append(.init(request: request, timingContext: context, performance: performance))
                    guard result.count <= 128 else { throw PlanningError.tooManyUnits }
                    previous = unit
                }
            }
        }
        return result
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
