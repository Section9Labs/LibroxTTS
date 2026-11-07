// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation

public struct SpeakerDecision: Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case explicitName, adjacentPronoun, adjacentAction, unresolved, ambiguous, noCharacterVoice, castLimit
    }
    public let offset: Int
    public let length: Int
    public let speakerID: String?
    public let name: String?
    public let reason: Reason
    /// Literal source evidence, not a generated explanation or confidence score.
    public let evidence: String?
}

public struct ChapterAttribution: Codable, Sendable {
    public let bookID: String
    public let chapterID: String
    /// Only dialogue with an assigned character voice. Unresolved spans remain
    /// contiguous narrator prose when passed to StoryNarrator.
    public let annotations: [DialogueAnnotation]
    public let decisions: [SpeakerDecision]
}

/// Localized explicit speech tags and labels across the narration catalog.
/// Existing English/Spanish narrow local continuations remain; other languages
/// require explicit names. Untagged turns never imply speaker alternation.
public struct SpeakerAttributor {
    public enum AttributionError: Error { case unsupportedLanguage, invalidChapter, tooManyCandidates }
    public static var supportedLanguageCodes: Set<String> { Set(NarrationLanguageRules.profiles.keys) }
    public init() {}

    public func analyze(_ text: String, bookID: String, chapterID: String,
                        cast: inout BookVoiceCast) throws -> ChapterAttribution {
        guard text.unicodeScalars.count <= PronunciationEngine.maximumInputScalars else {
            throw PronunciationError.inputTooLong(limit: PronunciationEngine.maximumInputScalars)
        }
        try cast.validate()
        guard cast.bookID == bookID else { throw BookVoiceCast.CastError.wrongBook }
        guard !chapterID.isEmpty, chapterID.utf8.count <= 128 else { throw AttributionError.invalidChapter }
        guard Self.supportedLanguageCodes.contains(cast.language.rawValue) else { throw AttributionError.unsupportedLanguage }
        if cast.language != .english && cast.language != .spanish {
            return try MultilingualSpeakerAttribution.analyze(text, bookID: bookID, chapterID: chapterID, cast: &cast)
        }
        let source = text as NSString
        let rules = try Rules(language: cast.language.pronunciationLanguage!)
        let sharedLabels = try MultilingualSpeakerAttribution.Matcher(language: cast.language.rawValue)
        var candidates = try StoryNarrator().quotedCandidates(in: text).map { NSRange(location: $0.offset, length: $0.length) }
        // Include punctuation immediately following closing quotation marks.
        candidates = candidates.map { range in
            var end = NSMaxRange(range)
            while end < source.length, ".,;:!?".utf16.contains(source.character(at: end)) { end += 1 }
            return NSRange(location: range.location, length: end - range.location)
        }
        if cast.language == .spanish {
            var cursor = 0
            for line in text.components(separatedBy: "\n") {
                let length = (line as NSString).length
                let leading = (line as NSString).rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
                if leading.location != NSNotFound, (line as NSString).character(at: leading.location) == 0x2014 {
                    let range = NSRange(location: cursor + leading.location, length: length - leading.location)
                    if !candidates.contains(where: { NSIntersectionRange($0, range).length > 0 }) { candidates.append(range) }
                }
                cursor += length + 1
            }
        }
        candidates.sort { $0.location < $1.location }
        guard candidates.count <= 256 else { throw AttributionError.tooManyCandidates }
        var pending = cast // Transactional: a thrown error must not partially assign a cast.
        var annotations: [DialogueAnnotation] = []
        var decisions: [SpeakerDecision] = []
        var previous: (name: String, end: Int)?
        var contextEvidence: [String: [BookVoiceCast.GenderEvidence]] = [:]
        let dash = try NSRegularExpression(pattern: "—")
        for range in candidates {
            let value = source.substring(with: range) as NSString
            var evidence: [Tag] = []
            let beforeStart = max(0, range.location - 240)
            let before = source.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart))
            if let tag = rules.prefixTag(before) { evidence.append(tag) }
            else if let tag = sharedLabels.explicitLabel(before) { evidence.append(Tag(name: tag.name, evidence: tag.evidence)) }
            let after = source.substring(with: NSRange(location: NSMaxRange(range), length: min(180, source.length - NSMaxRange(range))))
            let suffixTag = rules.suffixTag(after)
            if let suffixTag { evidence.append(suffixTag) }
            var embedded: [(Tag, NSRange)] = []
            for match in dash.matches(in: value as String, range: NSRange(location: 0, length: value.length)) {
                let start = NSMaxRange(match.range)
                if let tag = rules.suffixTag(value.substring(from: start)) {
                    let rest = NSRange(location: start, length: value.length - start)
                    let closing = value.range(of: "—", range: rest)
                    let end = closing.location == NSNotFound ? value.length : NSMaxRange(closing)
                    embedded.append((tag, NSRange(location: match.range.location, length: end - match.range.location)))
                }
            }
            evidence += embedded.map { $0.0 }
            if evidence.isEmpty {
                // "…," said Ana. She continued: "…" has a local antecedent.
                // A plain next quotation never inherits the previous speaker.
                if let previous, previous.end <= range.location, range.location - previous.end <= 180,
                   let continuation = rules.pronounContinuation(
                    source.substring(with: NSRange(location: previous.end, length: range.location - previous.end)),
                    name: previous.name) {
                    let prior = pending.characters.first { $0.id == pending.identity(for: previous.name) }
                    if prior?.gender == .unknown || prior?.gender == continuation.gender {
                        evidence.append(continuation)
                    }
                } else if let action = rules.actionTag(before) {
                    // A short, adjacent intransitive action beat, with no second
                    // person, has a named subject; no general coreference claim.
                    evidence.append(action)
                }
            }
            let identities = Set(evidence.map { pending.identity(for: $0.name) })
            let ambiguous = identities.count > 1 || embedded.count > 1
            let selected = ambiguous ? nil : evidence.first
            var character: BookVoiceCast.Character?
            if let selected {
                let identity = pending.identity(for: selected.name)
                let aliases = pending.aliases.filter { $0.value == identity }.map(\.key)
                let sourceEvidence: [BookVoiceCast.GenderEvidence]
                if let cached = contextEvidence[identity] {
                    sourceEvidence = cached
                } else {
                    sourceEvidence = try CharacterContext.evidence(for: selected.name, in: text, language: pending.language.pronunciationLanguage!,
                                                                   chapterID: chapterID, aliases: aliases)
                }
                var context = sourceEvidence
                if let gender = selected.gender, !context.contains(where: { $0.gender == gender }) {
                    context.append(.init(gender: gender, quote: selected.evidence, chapterID: chapterID))
                }
                character = pending.discover(selected.name, chapterID: chapterID, evidence: context)
                // At most 64 accepted identities, discarded after this analysis.
                // Repeated dialogue must not repeatedly scan the entire chapter.
                if let character { contextEvidence[character.id] = sourceEvidence }
            }
            let reason: SpeakerDecision.Reason
            if ambiguous { reason = .ambiguous }
            else if selected == nil { reason = .unresolved }
            else if character == nil { reason = .castLimit }
            else if character?.voiceID == nil { reason = .noCharacterVoice }
            else { reason = selected?.reason ?? .explicitName }
            decisions.append(.init(offset: range.location, length: range.length, speakerID: character?.id,
                                   name: character?.name ?? selected?.name, reason: reason, evidence: selected?.evidence))
            previous = character.map { ($0.name, NSMaxRange(range) + (suffixTag?.evidence.utf16.count ?? 0)) }
            guard let character, character.voiceID != nil else { continue }
            var ranges = [range]
            if let (_, tagRange) = embedded.first {
                ranges = [NSRange(location: range.location, length: tagRange.location),
                          NSRange(location: range.location + NSMaxRange(tagRange), length: range.length - NSMaxRange(tagRange))]
            }
            for piece in ranges where piece.length > 0 {
                let content = source.substring(with: piece)
                guard content.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                annotations.append(.init(offset: piece.location, length: piece.length, speakerID: character.id))
            }
        }
        // Validate exact source ranges and overlap before committing persisted identity changes.
        _ = try StoryNarrator().plan(text, narratorVoiceID: pending.narratorVoiceID,
                                    characterVoices: pending.characterVoices, dialogue: annotations, mode: .characterVoices)
        try pending.validate()
        cast = pending
        return .init(bookID: bookID, chapterID: chapterID, annotations: annotations, decisions: decisions)
    }

    private struct Tag {
        let name: String
        let evidence: String
        var reason: SpeakerDecision.Reason = .explicitName
        var gender: BookVoiceCast.Gender?
    }
    private struct Rules {
        let prefix: NSRegularExpression
        let prefixVerbFirst: NSRegularExpression
        let suffix: NSRegularExpression
        let suffixSubjectFirst: NSRegularExpression
        let continuation: NSRegularExpression
        let action: NSRegularExpression
        init(language: PronunciationLanguage) throws {
            let capital = #"\p{Lu}[\p{L}\p{M}’'-]{0,39}"#
            let title = #"(?:(?i:don|doña|señor|señora|sr\.|sra\.|mr\.|mrs\.|miss|ms\.)\s+)?"#
            let name = title + capital + #"(?:[ \t]+(?:(?:de|del|de la)[ \t]+)?"# + capital + #"){0,2}"#
            let verb = language == .spanish
                ? #"(?i:dijo|decía|preguntó|preguntaba|respondió|respondía|replicó|contestó|contestaba|exclamó|añadió|murmuró|susurró|gritó|repitió|observó|continuó|prosiguió|insistió|explicó|afirmó|declaró|advirtió|musitó)"#
                : #"(?i:said|asked|replied|answered|cried|added|whispered|shouted|murmured|remarked|called|continued|insisted|explained|declared|warned|muttered)"#
            let aside = #"(?:,[ \t]*[^,:\r\n.!?]{1,40},)?"#
            let clitic = language == .spanish ? #"(?:(?:le|les|me|nos|te|se)\s+)?"# : ""
            let reportingAdverb = language == .spanish
                ? #"(?:(?i:entonces|después|finalmente|lentamente|suavemente|secamente|tristemente|vivamente)[ \t]+)?"#
                : #"(?:(?i:then|finally|softly|quietly|sadly|slowly)[ \t]+)?"#
            prefix = try NSRegularExpression(pattern: #"(?<![\p{L}\p{M}])(?<name>"# + name + ")" + aside + #"\s+"# + clitic + verb + #"(?:\s+\p{Ll}[\p{Ll}\p{M}]{0,20}){0,2}[,:]\s*$"#)
            prefixVerbFirst = try NSRegularExpression(pattern: verb + #"\s+"# + reportingAdverb + #"(?<name>"# + name + #")[,:]\s*$"#)
            suffix = try NSRegularExpression(pattern: #"^[ \t,.;:—–-]*"# + clitic + verb + #"\s+"# + reportingAdverb + #"(?<name>"# + name + ")")
            suffixSubjectFirst = try NSRegularExpression(pattern: #"^[ \t,.;:—–-]*(?<name>"# + name + #")\s+"# + verb + #"\b"#)
            let pronoun = language == .spanish ? "ella|él" : "she|he"
            let continuationVerb = language == .spanish ? "continuó|prosiguió|añadió|repitió" : "continued|added|repeated"
            continuation = try NSRegularExpression(pattern: #"^[ \t.,;—–-]*(?<pronoun>(?i:"# + pronoun + #"))[ \t]+"#
                + clitic + "(?i:" + continuationVerb + #")[,:][ \t]*$"#)
            let actionVerb = language == .spanish ? "sonrió|suspiró|asintió|titubeó|vaciló" : "smiled|sighed|nodded|hesitated"
            action = try NSRegularExpression(pattern: #"(?:^|[.!?][ \t]+)(?<name>"# + name + #")[ \t]+(?i:"#
                + actionVerb + #")[.:][ \t]*$"#)
        }
        func tag(_ expression: NSRegularExpression, _ text: String) -> Tag? {
            let ns = text as NSString
            guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let head = ns.substring(to: match.range.location)
            guard head.range(of: #"\b(?:and|y)[ \t]*$"#, options: [.regularExpression, .caseInsensitive]) == nil else {
                return nil // "Alice and Bob said" is not an individual attribution.
            }
            var name = ns.substring(with: match.range(withName: "name"))
            // Sentence connectives are not part of an identity: "And Alice
            // said" names Alice, while "And I said" still has no named speaker.
            let connectives: Set<String> = ["and", "but", "then", "y", "pero", "entonces"]
            let sourceWords = name.split(separator: " ")
            if sourceWords.count > 1, let first = sourceWords.first, connectives.contains(first.lowercased()) {
                name = sourceWords.dropFirst().joined(separator: " ")
            }
            let key = BookVoiceCast.nameKey(name)
            let excluded: Set<String> = ["yo", "tú", "usted", "ustedes", "nosotros", "vosotros", "este", "esta", "ese", "esa", "él", "ella", "ellos", "ellas", "alguien", "nadie", "el", "la", "los", "las", "he", "she", "they", "someone", "the", "it", "i", "we", "you", "this", "that", "and", "but", "then", "y", "pero", "entonces", "no", "not", "nunca", "jamás", "never"]
            let words = key.split(separator: " ").map(String.init)
            let disallowedInsideName: Set<String> = ["i", "we", "you", "he", "she", "they", "and", "but",
                                                     "yo", "tú", "él", "ella", "ellos", "ellas", "y", "pero"]
            guard let first = words.first, !excluded.contains(first),
                  !words.contains(where: disallowedInsideName.contains) else { return nil }
            let tail = ns.substring(from: NSMaxRange(match.range)).lowercased()
            guard !tail.hasPrefix(" y "), !tail.hasPrefix(" and ") else { return nil }
            return Tag(name: name, evidence: ns.substring(with: match.range))
        }
        func prefixTag(_ text: String) -> Tag? { tag(prefix, text) ?? tag(prefixVerbFirst, text) }
        func suffixTag(_ text: String) -> Tag? {
            guard let result = tag(suffix, text) ?? tag(suffixSubjectFirst, text) else { return nil }
            let tail = (text as NSString).substring(from: result.evidence.utf16.count)
                .trimmingCharacters(in: .whitespaces)
            // "A said: «…». B replied: «…»" introduces the next quotation;
            // do not treat B's prefix as a conflicting suffix for A's speech.
            guard !tail.hasPrefix(":") else { return nil }
            return result
        }
        func actionTag(_ text: String) -> Tag? {
            guard var result = tag(action, text) else { return nil }
            result.reason = .adjacentAction
            return result
        }
        func pronounContinuation(_ text: String, name: String) -> Tag? {
            let ns = text as NSString
            guard let match = continuation.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let pronoun = ns.substring(with: match.range(withName: "pronoun")).lowercased()
            return Tag(name: name, evidence: text, reason: .adjacentPronoun,
                       gender: pronoun == "she" || pronoun == "ella" ? .female : .male)
        }
    }
}
