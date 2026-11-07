// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroPronunciation

public enum DialogueTimingRole: String, Sendable, Equatable {
    case unknown, narration, dialogue, attribution
}

/// Trusted document structure. A soft line wrap is not necessarily a paragraph.
public enum DialogueStructuralBreak: String, Sendable, Equatable {
    case none, paragraph, scene, chapter
}

/// Small boundary evidence, independent of rendering, voice selection, and audio.
/// IDs identify actual dialogue participants, never model voices or the narrator.
public struct DialogueTimingContext: Sendable, Equatable {
    public static let maximumEdgeScalars = 256
    public let previousTail: String
    public let nextHead: String
    public let previousSpeakerID: String?
    public let nextSpeakerID: String?
    public let previousRole: DialogueTimingRole
    public let nextRole: DialogueTimingRole
    public let structuralBreak: DialogueStructuralBreak
    public let sourceGap: String
    public let sourceGapIsComplete: Bool
    public let languageCode: String?

    public init(previousText: String, nextText: String,
                previousSpeakerID: String? = nil, nextSpeakerID: String? = nil,
                previousRole: DialogueTimingRole = .unknown, nextRole: DialogueTimingRole = .unknown,
                structuralBreak: DialogueStructuralBreak = .none, sourceGap: String = "",
                languageCode: String? = nil) {
        previousTail = String(String.UnicodeScalarView(previousText.unicodeScalars.suffix(Self.maximumEdgeScalars)))
        nextHead = String(String.UnicodeScalarView(nextText.unicodeScalars.prefix(Self.maximumEdgeScalars)))
        self.previousSpeakerID = Self.validID(previousSpeakerID)
        self.nextSpeakerID = Self.validID(nextSpeakerID)
        self.previousRole = previousRole; self.nextRole = nextRole
        self.structuralBreak = structuralBreak
        self.sourceGap = String(String.UnicodeScalarView(sourceGap.unicodeScalars.prefix(Self.maximumEdgeScalars)))
        sourceGapIsComplete = sourceGap.unicodeScalars.prefix(Self.maximumEdgeScalars + 1).count <= Self.maximumEdgeScalars
        self.languageCode = languageCode.map {
            String($0.unicodeScalars.prefix(16)).lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        }
    }

    private static func validID(_ value: String?) -> String? {
        guard let value, value.unicodeScalars.prefix(129).count <= 128,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

public enum DialogueTimingKind: String, Sendable, Equatable {
    case continuation, attribution, speakerTurn, sentence, paragraph, scene, chapter, ellipsis, interruption
}

public enum DialogueTimingReason: String, Sendable, Equatable {
    case noBoundaryEvidence, explicitAttributionRoles, quoteToReportingClause, reportingClauseToQuote
    case speakerIdentityChanged, speakerIdentityChangedAcrossParagraph
    case explicitSpanishDialogueTurn
    case terminalPunctuation, explicitParagraph, paragraphSeparator, explicitScene, explicitChapter
    case trailingEllipsis, trailingInterruption, interruptedSpeakerTurn
}

/// Tunable experimental targets in seconds, not measured human norms. Defaults do
/// not change existing playback. Classification sanitizes values to finite 0...3 s.
public struct DialogueTimingProfile: Sendable, Equatable {
    public var continuationSeconds: Double
    public var attributionSeconds: Double
    public var speakerTurnSeconds: Double
    public var paragraphTurnSeconds: Double
    public var sentenceSeconds: Double
    public var paragraphSeconds: Double
    public var sceneSeconds: Double
    public var chapterSeconds: Double
    public var ellipsisSeconds: Double
    public var interruptionSeconds: Double

    public init(continuationSeconds: Double = 0, attributionSeconds: Double = 0.06,
                speakerTurnSeconds: Double = 0.18, paragraphTurnSeconds: Double = 0.24,
                sentenceSeconds: Double = 0.22, paragraphSeconds: Double = 0.45,
                sceneSeconds: Double = 0.75, chapterSeconds: Double = 1,
                ellipsisSeconds: Double = 0.32, interruptionSeconds: Double = 0.04) {
        self.continuationSeconds = continuationSeconds; self.attributionSeconds = attributionSeconds
        self.speakerTurnSeconds = speakerTurnSeconds; self.paragraphTurnSeconds = paragraphTurnSeconds
        self.sentenceSeconds = sentenceSeconds; self.paragraphSeconds = paragraphSeconds
        self.sceneSeconds = sceneSeconds; self.chapterSeconds = chapterSeconds
        self.ellipsisSeconds = ellipsisSeconds; self.interruptionSeconds = interruptionSeconds
    }
}

public struct DialogueTimingDecision: Sendable, Equatable {
    public let kind: DialogueTimingKind
    public let reason: DialogueTimingReason
    /// Desired total boundary silence, not extra silence to stack on model edges.
    /// This API does not trim, synthesize, time-stretch, or overlap any audio.
    public let targetSeconds: Double
}

public enum DialogueTiming {
    public static let revision = "dialogue-timing-3"

    public static func classify(_ context: DialogueTimingContext,
                                profile: DialogueTimingProfile = .init()) -> DialogueTimingDecision {
        func result(_ kind: DialogueTimingKind, _ reason: DialogueTimingReason, _ seconds: Double) -> DialogueTimingDecision {
            .init(kind: kind, reason: reason, targetSeconds: seconds.isFinite ? min(3, max(0, seconds)) : 0)
        }
        let previous = context.previousTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = context.nextHead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !next.isEmpty else { return result(.continuation, .noBoundaryEvidence, 0) }
        if context.structuralBreak == .chapter { return result(.chapter, .explicitChapter, profile.chapterSeconds) }
        if context.structuralBreak == .scene { return result(.scene, .explicitScene, profile.sceneSeconds) }
        let paragraph = context.structuralBreak == .paragraph || hasParagraphSeparator(context)
        // A known participant change outranks a typographic dialogue paragraph,
        // but narrator and attribution roles cannot manufacture a character turn.
        let dialogueRoles = ![DialogueTimingRole.narration, .attribution].contains(context.previousRole)
            && ![DialogueTimingRole.narration, .attribution].contains(context.nextRole)
        let changedSpeaker = dialogueRoles && context.previousSpeakerID != nil && context.nextSpeakerID != nil
            && context.previousSpeakerID != context.nextSpeakerID

        // A printed Spanish turn marker can establish a turn boundary without
        // identifying its speaker. Do not alternate voices or infer a character.
        if paragraph, !changedSpeaker, context.languageCode == "es", context.previousRole == .dialogue,
           context.nextRole == .dialogue, next.hasPrefix("—") {
            return result(.speakerTurn, .explicitSpanishDialogueTurn, profile.paragraphTurnSeconds)
        }

        if !paragraph, context.sourceGapIsComplete,
           context.sourceGap.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
            if (context.previousRole == .dialogue && context.nextRole == .attribution)
                || (context.previousRole == .attribution && context.nextRole == .dialogue)
                || (context.previousRole == .attribution && context.nextRole == .attribution) {
                return result(.attribution, .explicitAttributionRoles, profile.attributionSeconds)
            }
            if (context.previousRole == .dialogue || endsQuote(previous)),
               context.nextRole != .dialogue,
               startsReportingClause(next, language: context.languageCode) {
                return result(.attribution, .quoteToReportingClause, profile.attributionSeconds)
            }
            if (context.nextRole == .dialogue || startsQuote(next)),
               context.previousRole != .dialogue,
               endsReportingClause(previous, language: context.languageCode) {
                return result(.attribution, .reportingClauseToQuote, profile.attributionSeconds)
            }
        }

        let ending = previous.trimmingCharacters(in: closingWrappers)
        if !paragraph || changedSpeaker {
            if ending.hasSuffix("—") || ending.hasSuffix("–") {
                return result(.interruption, changedSpeaker ? .interruptedSpeakerTurn : .trailingInterruption,
                              profile.interruptionSeconds)
            }
            if ending.hasSuffix("…") || ending.hasSuffix("...") {
                return result(.ellipsis, .trailingEllipsis, profile.ellipsisSeconds)
            }
        }
        if changedSpeaker {
            return result(.speakerTurn, paragraph ? .speakerIdentityChangedAcrossParagraph : .speakerIdentityChanged,
                          paragraph ? profile.paragraphTurnSeconds : profile.speakerTurnSeconds)
        }
        if paragraph {
            return result(.paragraph, context.structuralBreak == .paragraph ? .explicitParagraph : .paragraphSeparator,
                          profile.paragraphSeconds)
        }
        if ending.last.map({ ".!?。！？।॥؟‽⁈⁉‼".contains($0) }) == true {
            return result(.sentence, .terminalPunctuation, profile.sentenceSeconds)
        }
        return result(.continuation, .noBoundaryEvidence, profile.continuationSeconds)
    }

    private static let closingWrappers = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\"'’”»›」』】)]}）〉》"))
    private static let attributionLeading = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ",，—–-\"'’”»›」』"))

    private static func hasParagraphSeparator(_ context: DialogueTimingContext) -> Bool {
        let previous = context.previousTail.unicodeScalars.reversed().prefix { $0.properties.isWhitespace }.reversed()
        let next = context.nextHead.unicodeScalars.prefix { $0.properties.isWhitespace }
        let gap = String(String.UnicodeScalarView(previous)) + context.sourceGap + String(String.UnicodeScalarView(next))
        if gap.contains("\u{2029}") { return true }
        let normalized = gap.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A single line break may be a soft wrap. Blank lines and U+2029 are
        // structural evidence; the host can explicitly mark other paragraph breaks.
        return normalized.range(of: #"\n[\t ]*\n"#, options: .regularExpression) != nil
    }

    private static func endsQuote(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",，;；")))
        return value.last.map { "\"'’”»›」』".contains($0) } == true
    }

    private static func startsQuote(_ text: String) -> Bool {
        text.first.map { "\"'‘“„”«‹「『".contains($0) } == true
    }

    private static func startsReportingClause(_ text: String, language: String?) -> Bool {
        guard language == "en" || language == "es" else {
            return language.map { NarrationLanguageRules.beginsWithNamedSpeechTag(text, language: $0) } ?? false
        }
        let value = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: attributionLeading)
        let firstClause = String(value.prefix { !".!?。！？;；\n\r".contains($0) })
        // Only a leading speech verb or subject + speech verb qualifies. A later
        // emotional word or mention of speech in ordinary narration is insufficient.
        let pronouns = language == "es" ? "él|ella|ellos|ellas" : "he|she|they|i|we|you"
        let name = #"\p{Lu}[\p{L}\p{M}'’\-]{0,30}(?:\s+\p{Lu}[\p{L}\p{M}'’\-]{0,30}){0,2}"#
        let verbs = language == "es"
            ? "dijo|preguntó|respondió|contestó|replicó|añadió|continuó|susurró|murmuró|musitó|gritó|exclamó"
            : "said|asked|replied|answered|added|continued|whispered|murmured|shouted|exclaimed|cried"
        let pattern = "^(?:(?:(?i:" + pronouns + ")|" + name + ")\\s+)?(?i:" + verbs + ")\\b"
        return firstClause.range(of: pattern, options: .regularExpression) != nil
    }

    private static func endsReportingClause(_ text: String, language: String?) -> Bool {
        // A tag that has ended in a full stop is a completed sentence, not an
        // instruction to shorten the next quoted sentence's boundary.
        guard text.last.map({ ",:，：—–".contains($0) }) == true else { return false }
        if let language, !["en", "es"].contains(language) {
            return NarrationLanguageRules.endsWithNamedSpeechTag(text, language: language)
        }
        var clause = text
        if let cut = clause.lastIndex(where: { ".!?。！？;；\n\r\"”»」』".contains($0) }) {
            clause = String(clause[clause.index(after: cut)...])
        }
        return startsReportingClause(clause, language: language)
    }
}
