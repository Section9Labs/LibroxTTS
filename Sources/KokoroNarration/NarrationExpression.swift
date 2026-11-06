// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog

/// Legacy duration labels. New renderers can consume `NarrationProsody` punctuation
/// at the listener's selected rate instead; these labels are not an emotion model.
public enum NarrationExpression: String, Sendable, Equatable {
    case neutral, measured, brisk, question

    public var speedMultiplier: Float {
        switch self {
        case .neutral: 1
        case .measured: 0.96
        case .brisk: 1.03
        case .question: 0.985
        }
    }

    /// Compatibility classification for English/Spanish dialogue. Other languages
    /// receive punctuation analysis through `NarrationProsody`, without guessed acting.
    public static func infer(dialogue: String, followingAttribution: String,
                             voiceID: String) -> Self {
        guard let language = Voice.named(voiceID)?.language,
              language == .english || language == .spanish else { return .neutral }
        return NarrationProsody.analyze(text: dialogue, followingAttribution: followingAttribution,
                                       voiceID: voiceID).expression
    }
}

/// The written ending, independent of the speaker's identity or emotional state.
public enum NarrationTerminal: String, Sendable, Equatable {
    case none, statement, question, exclamation, questionExclamation, suspension, interruption
}

/// A conservative syntactic classification, never a fixed pitch prescription.
/// Rhetorical intent and the direction of a tag question cannot be established from
/// punctuation alone; ambiguous forms remain `unspecified`.
public enum NarrationQuestionKind: String, Sendable, Equatable {
    case none, informationSeeking, yesNo, alternative, tag, unspecified
}

/// Bounded, renderer-independent evidence from one synthesis unit. This carries no
/// hidden prompt, invented words, pitch arrows, or changes to lexical stress.
public struct NarrationProsody: Sendable, Equatable {
    public static let revision = "book-expression-2"
    public static let maximumTextScalars = 4_096
    public let terminal: NarrationTerminal
    public let questionKind: NarrationQuestionKind
    public let expression: NarrationExpression
    public let hasMultipleSentences: Bool
    /// Kokoro-supported terminal tokens, including the written order of `?!` / `!?`.
    public let terminalPhonemes: String

    public static func analyze(text: String, followingAttribution: String = "",
                               voiceID: String) -> Self {
        guard let language = Voice.named(voiceID)?.language else { return empty }
        return analyze(text: text, followingAttribution: followingAttribution, languageCode: language.rawValue)
    }

    public static func analyze(text: String, followingAttribution: String = "",
                               languageCode: String) -> Self {
        // Do not classify a truncated sentence as if it were a complete one. Scalar
        // bounds also protect against pathological combining-character clusters.
        guard text.unicodeScalars.prefix(maximumTextScalars + 1).count <= maximumTextScalars else { return empty }
        let language = Language(identifier: languageCode)
        let spoken = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: wrappers)
        let ending = terminalSuffix(spoken)
        let body = String(spoken.dropLast(ending.sourceCount))
        let multiple = body.contains { ".!?。！？।॥؟‽⁈⁉".contains($0) }
        let question = ending.kind == .question || ending.kind == .questionExclamation
        let kind: NarrationQuestionKind = question
            ? language.map { questionKind(body, language: $0, multiple: multiple) } ?? .unspecified : .none
        let tag = language.flatMap { attributionExpression(followingAttribution, language: $0) }
        let expression: NarrationExpression
        if let tag { expression = tag }
        else if !multiple, language == .english || language == .spanish {
            switch ending.kind {
            case .question: expression = .question
            default: expression = .neutral
            }
        } else { expression = .neutral }
        return .init(terminal: ending.kind, questionKind: kind, expression: expression,
                     hasMultipleSentences: multiple, terminalPhonemes: ending.phonemes)
    }

    /// Repair only a missing/normalized final punctuation token after G2P. Retains
    /// every phoneme, stress and tone marker and every internal pause. Never call on
    /// a continuation chunk using the full sentence's analysis. If the result would
    /// exceed the renderer's input budget, the original is returned for re-planning.
    public func preservingTerminalPunctuation(in phonemes: String, maximumScalars: Int = 510) -> String {
        guard maximumScalars > 0, maximumScalars <= Self.maximumTextScalars,
              !terminalPhonemes.isEmpty,
              phonemes.unicodeScalars.prefix(maximumScalars + 1).count <= maximumScalars else { return phonemes }
        // Keep closing quotation marks after the repaired punctuation.
        let tail = phonemes.reversed().prefix { Self.wrappers.containsAllScalars(of: $0) }
        let closing = String(tail.reversed())
        let core = String(phonemes.dropLast(tail.count))
        let old = Self.terminalSuffix(core)
        let stem = String(core.dropLast(old.sourceCount))
        guard stem.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else { return phonemes }
        let result = stem + terminalPhonemes + closing
        return result.unicodeScalars.count <= maximumScalars ? result : phonemes
    }

    private static let empty = Self(terminal: .none, questionKind: .none, expression: .neutral,
                                    hasMultipleSentences: false, terminalPhonemes: "")
    private static let wrappers = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\"'‘’“”«»‹›「」『』【】()[]{}（）"))

    private static func terminalSuffix(_ text: String) -> (kind: NarrationTerminal, phonemes: String, sourceCount: Int) {
        let suffix = String(text.reversed().prefix { ".!?…。！？।॥؟‽⁈⁉‼—–".contains($0) }.reversed())
        guard !suffix.isEmpty else { return (.none, "", 0) }
        var marks = ""
        var punctuation = ""
        let normalizedSuffix = suffix.replacingOccurrences(of: #"\.{3,}"#, with: "…", options: .regularExpression)
        for c in normalizedSuffix {
            let normalized: String
            switch c {
            case "?", "？", "؟": normalized = "?"
            case "!", "！", "‼": normalized = "!"
            case "‽", "⁈": normalized = "?!"
            case "⁉": normalized = "!?"
            case "…": normalized = "…"
            default: normalized = ""
            }
            for mark in normalized {
                if mark == "…" {
                    if punctuation.last != "…" { punctuation.append(mark) }
                } else if !marks.contains(mark) {
                    marks.append(mark)
                    punctuation.append(mark)
                }
            }
        }
        // Keep the position of hesitation relative to a question/exclamation.
        if marks.contains("?"), marks.contains("!") { return (.questionExclamation, punctuation, suffix.count) }
        if marks == "?" { return (.question, punctuation, suffix.count) }
        if marks == "!" { return (.exclamation, punctuation, suffix.count) }
        if suffix.last == "—" || suffix.last == "–" { return (.interruption, "—", suffix.count) }
        if suffix.contains("…") || suffix.contains("...") { return (.suspension, "…", suffix.count) }
        return (.statement, ".", suffix.count)
    }

    private static func questionKind(_ body: String, language: Language, multiple: Bool) -> NarrationQuestionKind {
        guard !multiple else { return .unspecified }
        let text = body.lowercased().trimmingCharacters(in: wrappers.union(
            CharacterSet(charactersIn: "¿¡—–")))
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        switch language {
        case .english:
            if matches(#",\s*(?:(?:is|are|was|were|do|does|did|have|has|had|can|could|will|would|should|must)(?:n't| not)?\s+(?:i|you|he|she|it|we|they)|right|okay|ok)\s*$"#) { return .tag }
            if matches(#"\bor\b"#) { return .alternative }
            if matches(#"^(?:(?:for|to|with|from|about|at|in|on)\s+)?(?:what|which|who|whom|whose|where|when|why|how)\b"#) { return .informationSeeking }
            if matches(#"^(?:am|is|are|was|were|do|does|did|have|has|had|can|could|will|would|shall|should|may|might|must)(?:n't)?\b"#) { return .yesNo }
        case .spanish:
            if matches(#",\s*¿?\s*(?:no|verdad|cierto|eh)\s*$"#) { return .tag }
            if matches(#"\b(?:o|u)\b"#) { return .alternative }
            if matches(#"^(?:(?:a|de|con|desde|en|hacia|hasta|para|por|sin|sobre)\s+)?(?:qué|cuál|cuáles|quién|quiénes|cuándo|dónde|adónde|cómo|cuánto|cuánta|cuántos|cuántas)\b"#) { return .informationSeeking }
            // Spanish has no obligatory auxiliary inversion. Recognize common
            // explicit verb-led polar forms; fragments/echoes stay unspecified.
            if matches(#"^(?:no\s+)?(?:es|son|era|eran|está|estás|están|estamos|estáis|estaba|estabas|hay|ha|has|han|habéis|hemos|puedo|puede|puedes|pueden|podemos|queréis|quieres|quiere|quieren|sabes|sabe|saben|tienes|tiene|tienen|vienes|viene|vienen|vas|va|van|vamos)\b"#) { return .yesNo }
        default: break // Punctuation is universal; grammar rules are not.
        }
        return .unspecified
    }

    /// Read only the first local attribution clause, never a later description.
    /// Named subjects must retain their capitalization; arbitrary prose is not a tag.
    private static func attributionExpression(_ following: String, language: Language) -> NarrationExpression? {
        guard language == .english || language == .spanish else { return nil }
        let bounded = String(String.UnicodeScalarView(following.unicodeScalars.prefix(192)))
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: wrappers.union(CharacterSet(charactersIn: "—–-,.")))
        let tag = String(bounded.prefix { !".!?。！？\n\r;:".contains($0) })
        guard !tag.isEmpty else { return nil }
        if tag.range(of: #"(?i)\b(no|not|never|nunca|pero|but|didn't|wasn't|isn't)\b"#,
                     options: .regularExpression) != nil { return .neutral }
        let subject = language == .spanish ? "él|ella|ellos|ellas" : "he|she|they|i|we|you"
        let name = #"\p{Lu}[\p{L}\p{M}'’\-]{0,30}(?:\s+\p{Lu}[\p{L}\p{M}'’\-]{0,30}){0,2}"#
        let prefix = "^(?:(?:(?i:" + subject + ")|" + name + ")\\s+)?"
        let measured = language == .spanish ? "susurró|murmuró|musitó" : "whispered|murmured"
        let brisk = language == .spanish ? "gritó|exclamó" : "shouted|exclaimed"
        if tag.range(of: prefix + "(?i:" + measured + ")\\b", options: .regularExpression) != nil { return .measured }
        if tag.range(of: prefix + "(?i:" + brisk + ")\\b", options: .regularExpression) != nil { return .brisk }
        let verb = language == .spanish ? "dijo|respondió|replicó|preguntó" : "said|replied|answered|asked"
        let manner = language == .spanish ? "despacio|lentamente|suavemente|en voz baja" : "slowly|softly|quietly"
        if tag.range(of: prefix + "(?i:(?:" + verb + ")\\s+(?:" + manner + "))\\b",
                     options: .regularExpression) != nil { return .measured }
        return nil
    }
}

private extension CharacterSet {
    func containsAllScalars(of character: Character) -> Bool {
        character.unicodeScalars.allSatisfy(contains)
    }
}
