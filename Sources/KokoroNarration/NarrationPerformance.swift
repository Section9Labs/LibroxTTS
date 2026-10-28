// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog

/// Authored delivery vocabulary, not a promise that a renderer supports these styles.
public enum NarrationVocalDelivery: String, Sendable, CaseIterable {
    case neutral, whisper, soft, shout, urgent, tender, solemn, cheerful, firm, hesitant, weary, playful
}

/// Relative authored strength, not a probability or a calibrated acoustic quantity.
public enum NarrationPerformanceStrength: String, Sendable {
    case subtle, moderate, strong
}

public struct NarrationPerformanceOverride: Sendable, Equatable {
    public let delivery: NarrationVocalDelivery
    public let strength: NarrationPerformanceStrength

    public init(delivery: NarrationVocalDelivery, strength: NarrationPerformanceStrength = .moderate) {
        self.delivery = delivery
        self.strength = strength
    }
}

public struct NarrationPerformanceEvidence: Sendable, Equatable {
    public enum Source: String, Sendable {
        case none, explicitOverride, followingAttribution, mood, speechAct
    }
    public let source: Source
    public let cue: String?
    public let ruleID: String?
    /// UTF-16 offsets in followingAttribution for attribution/mood, or in spoken
    /// text for speechAct. Explicit overrides and neutral results have no range.
    public let evidenceRange: Range<Int>?
}

/// Only controls exposed by Chatterbox Multilingual. Suggestions are conservative
/// authored intensity heuristics, not measured emotion/style reproduction.
public struct NarrationChatterboxSuggestion: Sendable, Equatable {
    public let exaggeration: Float
    public let cfgWeight: Float
    /// All nonneutral named deliveries remain unmapped: exaggeration is not a whisper/shout switch.
    public let unmappedDelivery: NarrationVocalDelivery?
    public let unmappedMood: NarrationMood?
    /// Whether these EN/ES inference rules apply, not the model's language support.
    public let languageSupported: Bool
}

/// A stateless description of one unit. Never rewrites text, voice identity,
/// pronunciation, source offsets, pauses or the listener's requested rate.
public struct NarrationPerformance: Sendable, Equatable {
    public static let revision = "narration-performance-1"
    public static let maximumAttributionUTF16 = 192
    public static let maximumTextUTF16 = 4_096
    public let languageCode: String
    public let delivery: NarrationVocalDelivery
    public let strength: NarrationPerformanceStrength
    public let evidence: NarrationPerformanceEvidence
    public let mood: NarrationMoodEvidence
    public let speechAct: NarrationActEvidence
    public let prosody: NarrationProsody
    /// Preserve the planner's compatibility label; this layer applies no speed multiplier.
    public let expression: NarrationExpression

    public static func analyze(unit: BookNarrationUnit, followingAttribution: String = "",
                               languageCode: String, override: NarrationPerformanceOverride? = nil) -> Self {
        make(text: unit.text, followingAttribution: followingAttribution, languageCode: languageCode,
             override: override, prosody: unit.prosody, speechAct: unit.speechAct, expression: unit.expression,
             inferSpokenEvidence: unit.role == .dialogue || unit.role == .unknown)
    }

    public static func analyze(text: String, followingAttribution: String = "",
                               languageCode: String, override: NarrationPerformanceOverride? = nil) -> Self {
        make(text: text, followingAttribution: followingAttribution, languageCode: languageCode,
             override: override, prosody: nil, speechAct: nil, expression: nil)
    }

    public var chatterboxSuggestion: NarrationChatterboxSuggestion {
        let supported = Self.supports(languageCode)
        var target: Float = 0.5
        if supported || (evidence.source == .explicitOverride && Self.chatterboxLanguages.contains(languageCode)) {
            switch evidence.source {
            case .mood:
                switch mood.mood {
                case .angry, .joyful, .fearful: target = 0.65
                case .sad, .relieved: target = 0.4
                case .neutral: break
                }
            case .speechAct:
                switch speechAct.act {
                case .urgentCommand, .surprise: target = 0.65
                case .hesitation, .reassurance: target = 0.4
                default: break
                }
            default:
                switch delivery {
                case .whisper, .soft, .tender, .solemn, .weary: target = 0.35
                case .shout, .urgent: target = 0.7
                case .cheerful, .firm, .playful: target = 0.6
                case .hesitant: target = 0.4
                case .neutral: break
                }
            }
        }
        let weight: Float = switch strength { case .subtle: 0.5; case .moderate: 0.75; case .strong: 1 }
        let intensity = 0.5 + (target - 0.5) * weight
        return .init(exaggeration: intensity, cfgWeight: intensity > 0.6 ? 0.4 : 0.5,
                     unmappedDelivery: delivery == .neutral ? nil : delivery,
                     unmappedMood: mood.mood == .neutral ? nil : mood.mood, languageSupported: supported)
    }

    private static func make(text: String, followingAttribution: String, languageCode: String,
                             override: NarrationPerformanceOverride?, prosody: NarrationProsody?,
                             speechAct: NarrationActEvidence?, expression: NarrationExpression?, inferSpokenEvidence: Bool = true) -> Self {
        let code = String(languageCode.unicodeScalars.prefix(16)).lowercased().replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
        let language = Language(rawValue: code)
        let boundedText = text.utf16.prefix(maximumTextUTF16 + 1).count <= maximumTextUTF16
        let boundedAttribution = followingAttribution.utf16.prefix(maximumAttributionUTF16 + 1).count <= maximumAttributionUTF16
        let local = inferSpokenEvidence && boundedText && boundedAttribution && supports(code) ? followingAttribution : ""
        // Existing prosody requires a catalog voice solely to choose language rules.
        // This analysis-only lookup never changes the unit's actual voice identity.
        let analysisVoice = language.map { Voice.preferred(for: $0).id } ?? "af_heart"
        let analyzed = NarrationProsody.analyze(text: boundedText ? text : "", followingAttribution: local, voiceID: analysisVoice)
        // Reuse punctuation parsing for languages without a Kokoro catalog voice,
        // but never borrow English grammar or a legacy expression for them.
        let universal = NarrationProsody(terminal: analyzed.terminal,
            questionKind: analyzed.terminal == .question || analyzed.terminal == .questionExclamation ? .unspecified : .none,
            expression: .neutral, hasMultipleSentences: analyzed.hasMultipleSentences, terminalPhonemes: analyzed.terminalPhonemes)
        let prosody = prosody ?? (language == nil ? universal : analyzed)
        let act = speechAct ?? NarrationExpressionLexicon.analyze(text: boundedText && inferSpokenEvidence ? text : "", language: language)
        let mood = NarrationMoodDetector.analyze(followingAttribution: local, languageCode: code)
        let clause = localClause(local)
        let delivery: NarrationVocalDelivery
        let strength: NarrationPerformanceStrength
        let evidence: NarrationPerformanceEvidence
        if let override {
            delivery = override.delivery
            strength = override.strength
            evidence = .init(source: .explicitOverride, cue: nil, ruleID: "override.delivery", evidenceRange: nil)
        } else if let clause, let match = vocalRule(clause.text, language: code) {
            delivery = match.delivery
            strength = match.strength
            evidence = .init(source: .followingAttribution, cue: clause.text, ruleID: match.id, evidenceRange: clause.range)
        } else if mood.mood != .neutral {
            delivery = .neutral
            strength = .moderate
            evidence = .init(source: .mood, cue: mood.cue, ruleID: mood.ruleID, evidenceRange: clause?.range)
        } else if inferSpokenEvidence, supports(code), act.act != .neutral {
            delivery = .neutral
            strength = .moderate
            let cue = act.evidenceRange.flatMap { Range(NSRange(location: $0.lowerBound, length: $0.count), in: text) }.map { String(text[$0]) }
            evidence = .init(source: .speechAct, cue: cue, ruleID: act.ruleID, evidenceRange: act.evidenceRange)
        } else {
            delivery = .neutral
            strength = .subtle
            evidence = .init(source: .none, cue: nil, ruleID: nil, evidenceRange: nil)
        }
        return .init(languageCode: code, delivery: delivery, strength: strength, evidence: evidence,
                     mood: mood, speechAct: act, prosody: prosody, expression: expression ?? prosody.expression)
    }

    private static let chatterboxLanguages: Set<String> = ["ar", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "it", "ja", "ko", "ms", "nl", "no", "pl", "pt", "ru", "sv", "sw", "tr", "zh"]

    private static func supports(_ language: String) -> Bool { language == "en" || language == "es" }

    private static func localClause(_ source: String) -> (text: String, range: Range<Int>)? {
        // Do not skip periods/newlines: a later sentence or paragraph is not a tag.
        let leading = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",—–"))
        var start = source.startIndex
        while start < source.endIndex, source[start].unicodeScalars.allSatisfy(leading.contains) {
            start = source.index(after: start)
        }
        var end = start
        while end < source.endIndex, !".!?;:\n\r。！？".contains(source[end]) { end = source.index(after: end) }
        while end > start, source[source.index(before: end)].isWhitespace { end = source.index(before: end) }
        guard start < end else { return nil }
        let range = NSRange(start..<end, in: source)
        return (String(source[start..<end]), range.location..<(range.location + range.length))
    }

    private struct VocalRule {
        let id: String
        let delivery: NarrationVocalDelivery
        let strength: NarrationPerformanceStrength
    }

    private static func vocalRule(_ original: String, language: String) -> VocalRule? {
        guard supports(language) else { return nil }
        let clause = original.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "’", with: "'")
        // Whole-clause matching additionally rejects quoted cues, other clauses,
        // hypothetical acting and arbitrary objects after a reporting verb.
        guard clause.range(of: #"(?i)\b(not|no|never|without|but|didn't|wasn't|isn't|cannot|can't|nunca|sin|pero|aunque|despite|pretend\w*|fingi\w*)\b"#,
                           options: .regularExpression) == nil else { return nil }
        let subjects = language == "en" ? "he|she|they|I|we|you" : "él|ella|ellos|ellas"
        let name = #"\p{Lu}[\p{L}\p{M}'\-]{0,30}(?:\s+\p{Lu}[\p{L}\p{M}'\-]{0,30}){0,2}"#
        let subject = "(?:(?i:" + subjects + ")|" + name + ")"
        let prefix = "(?:" + subject + "\\s+)?"
        let suffix = "(?:\\s+" + subject + ")?"
        let verbs = language == "en" ? "said|replied|answered|asked" : "dijo|respondió|replicó|preguntó"
        let definitions: [(NarrationVocalDelivery, NarrationPerformanceStrength, String?, String)] = language == "en" ? [
            (.whisper, .moderate, "whispered", "in a whisper"),
            (.soft, .subtle, "murmured", "softly|quietly|in a low voice"),
            (.shout, .strong, "shouted|yelled", "loudly|at the top of (?:his|her|their) voice"),
            (.urgent, .strong, nil, "urgently|with urgency"),
            (.tender, .subtle, nil, "tenderly|gently|with tenderness"),
            (.solemn, .moderate, nil, "solemnly|gravely"),
            (.cheerful, .moderate, nil, "cheerfully|brightly"),
            (.firm, .moderate, nil, "firmly|resolutely"),
            (.hesitant, .subtle, "stammered", "hesitantly|uncertainly"),
            (.weary, .subtle, nil, "wearily|tiredly"),
            (.playful, .moderate, nil, "playfully|teasingly")
        ] : [
            (.whisper, .moderate, "susurró|musitó", "en un susurro"),
            (.soft, .subtle, "murmuró", "suavemente|en voz baja"),
            (.shout, .strong, "gritó|vociferó", "en voz alta|a gritos"),
            (.urgent, .strong, nil, "con urgencia|apremiantemente"),
            (.tender, .subtle, nil, "con ternura|tiernamente|con dulzura"),
            (.solemn, .moderate, nil, "solemnemente|con solemnidad"),
            (.cheerful, .moderate, nil, "alegremente|con alegría"),
            (.firm, .moderate, nil, "con firmeza|firmemente"),
            (.hesitant, .subtle, "tartamudeó", "con vacilación|vacilante"),
            (.weary, .subtle, nil, "con cansancio|cansadamente"),
            (.playful, .moderate, nil, "en tono juguetón|juguetonamente")
        ]
        for (delivery, strength, verb, manner) in definitions {
            let direct = verb.map { "(?:" + prefix + "(?i:" + $0 + ")|(?i:" + $0 + ")" + suffix + ")" }
            let reporting = "(?i:" + verbs + ")"
            let modifier = "(?i:" + manner + ")"
            let modified = "(?:" + prefix + reporting + "\\s+" + modifier + "|" + reporting + "\\s+" + subject + "\\s+" + modifier + "|" + reporting + "\\s+" + modifier + suffix + ")"
            let pattern = "^(?:" + [direct, modified].compactMap { $0 }.joined(separator: "|") + ")$"
            if clause.range(of: pattern, options: .regularExpression) != nil {
                return .init(id: language + ".delivery." + delivery.rawValue, delivery: delivery,
                             strength: strength)
            }
        }
        return nil
    }
}
