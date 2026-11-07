import Foundation

/// Shared conservative attribution for literal names in localized speech tags
/// and explicitly labelled quotations. No guessed alternation or cross-paragraph
/// pronoun resolution. Uncertain cases retain the narrator.
enum MultilingualSpeakerAttribution {
    struct Tag { let name: String; let evidence: String }

    static func analyze(_ text: String, bookID: String, chapterID: String,
                        cast: inout BookVoiceCast) throws -> ChapterAttribution {
        let source = text as NSString
        let matcher = try Matcher(language: cast.language.rawValue)
        let candidates = try StoryNarrator().quotedCandidates(in: text)
        var pending = cast
        var decisions: [SpeakerDecision] = [], annotations: [DialogueAnnotation] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let end = candidate.offset + candidate.length
            let start = max(0, candidate.offset - 240)
            let before = source.substring(with: NSRange(location: start, length: candidate.offset - start))
            let after = source.substring(with: NSRange(location: end, length: min(180, source.length - end)))
            let tags = [matcher.prefix(before), matcher.suffix(after)].compactMap { $0 }
            let identities = Set(tags.map { pending.identity(for: $0.name) })
            let ambiguous = identities.count > 1
            let selected = ambiguous ? nil : tags.first
            let character = selected.flatMap { pending.discover($0.name, chapterID: chapterID) }
            let reason: SpeakerDecision.Reason = ambiguous ? .ambiguous : selected == nil ? .unresolved
                : character == nil ? .castLimit : character?.voiceID == nil ? .noCharacterVoice : .explicitName
            decisions.append(.init(offset: candidate.offset, length: candidate.length, speakerID: character?.id,
                name: character?.name, reason: reason, evidence: selected?.evidence))
            if let character, character.voiceID != nil {
                annotations.append(.init(offset: candidate.offset, length: candidate.length, speakerID: character.id))
            }
        }
        _ = try StoryNarrator().plan(text, narratorVoiceID: pending.narratorVoiceID,
            characterVoices: pending.characterVoices, dialogue: annotations, mode: .characterVoices)
        try pending.validate()
        cast = pending
        return .init(bookID: bookID, chapterID: chapterID, annotations: annotations, decisions: decisions)
    }

    struct Matcher {
        private let profile: NarrationLanguageRules.Profile
        private let rejectsEmbeddedReportingVerb: Bool
        private let prefixes: [NSRegularExpression]
        private let suffixes: [NSRegularExpression]
        init(language: String) throws {
            guard let profile = NarrationLanguageRules.profiles[language] else {
                throw SpeakerAttributor.AttributionError.unsupportedLanguage
            }
            self.profile = profile
            self.rejectsEmbeddedReportingVerb = ["ja", "zh"].contains(language)
            let uncased = ["ar", "hi", "ja", "ko", "zh"].contains(language)
            let word = uncased ? #"[\p{L}\p{M}]{1,32}"# : #"\p{Lu}[\p{L}\p{M}’'\-]{0,39}"#
            let name = #"(?<name>"# + word + (uncased ? "" : "(?:[ \\t]+" + word + "){0,2}") + ")"
            let verb = "(?i:" + profile.reportingVerbs.sorted { $0.count > $1.count }
                .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
            let boundary = #"(?:^|[.!?。！？؛][ \t]*)"#
            let colon = #"[ \t]*[:：,，][ \t]*$"#
            let ending = #"(?=$|[ \t.,;:!?。！？،؛])"#
            var prefix = [#"^[ \t]*"# + name + #"[ \t]*[:：][ \t]*$"#]
            var suffix: [String] = []
            switch language {
            case "ja":
                prefix += [boundary + name + "(?:は|が)" + verb + colon]
                suffix = [#"^[ \t、,]*(?:と)?"# + name + "(?:は|が)" + verb + ending]
            case "ko":
                prefix += [boundary + name + "(?:은|는|이|가)[ \\t]+" + verb + colon]
                suffix = [#"^[ \t,]*(?:라고[ \t]+)?"# + name + "(?:은|는|이|가)[ \\t]+" + verb + ending]
            case "zh":
                prefix += [boundary + name + verb + colon]
                suffix = [#"^[ \t，,]*"# + name + verb + ending]
            case "hi":
                prefix += [boundary + name + "[ \\t]+ने[ \\t]+" + verb + colon]
                suffix = [#"^[ \t,]*"# + name + "[ \\t]+ने[ \\t]+" + verb + #"(?=$|[ \t।.!?,])"#]
            default:
                prefix += [boundary + name + "[ \\t]+" + verb + colon,
                           boundary + verb + "[ \\t]+" + name + colon]
                suffix = [#"^[ \t,،؛.;:—–-]*"# + name + "[ \\t]+" + verb + ending,
                          #"^[ \t,،؛.;:—–-]*"# + verb + "[ \\t]+" + name + ending]
            }
            // Prefer grammatical tags over a label: Japanese/Chinese do not
            // separate the name and reporting clause with spaces.
            prefix.append(prefix.removeFirst())
            prefixes = try prefix.map { try NSRegularExpression(pattern: $0) }
            suffixes = try suffix.map { try NSRegularExpression(pattern: $0) }
        }
        private func tag(_ patterns: [NSRegularExpression], _ text: String, suffix: Bool) -> Tag? {
            let ns = text as NSString
            for pattern in patterns {
                guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
                let name = ns.substring(with: match.range(withName: "name"))
                guard !rejectsEmbeddedReportingVerb || !profile.reportingVerbs.contains(where: { name.hasSuffix($0) }) else { continue }
                let words = BookVoiceCast.nameKey(name).split(whereSeparator: \.isWhitespace).map(String.init)
                guard !words.isEmpty, !words.contains(where: profile.excludedNames.contains),
                      !words.contains(where: profile.conjunctions.contains),
                      !words.contains(where: Self.reserved.contains) else { continue }
                let head = ns.substring(to: match.range.location).split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() }
                let tail = ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces)
                let next = tail.split(whereSeparator: { !$0.isLetter }).first.map { $0.lowercased() }
                guard head.map({ !profile.conjunctions.contains($0) }) ?? true,
                      next.map({ !profile.conjunctions.contains($0) }) ?? true,
                      !suffix || (!tail.hasPrefix(":") && !tail.hasPrefix("：")) else { continue }
                return .init(name: name, evidence: ns.substring(with: match.range))
            }
            return nil
        }
        func explicitLabel(_ text: String) -> Tag? {
            tag(Array(prefixes.suffix(1)), text.components(separatedBy: .newlines).last ?? text, suffix: false)
        }
        func prefix(_ text: String) -> Tag? {
            // A speaker label must begin a line, not an arbitrary preceding clause.
            let line = text.components(separatedBy: .newlines).last ?? text
            return tag(prefixes, line, suffix: false)
        }
        func suffix(_ text: String) -> Tag? {
            tag(suffixes, text.components(separatedBy: .newlines).first ?? text, suffix: true)
        }
        private static let reserved: Set<String> = ["note", "chapter", "title", "summary", "nota", "capítulo", "chapitre", "kapitel", "hoofdstuk", "luku", "peatükk", "rozdział", "kapitola", "poglavje", "poglavlje", "глава", "розділ", "κεφάλαιο", "bölüm", "bab", "chương", "ملاحظة", "فصل", "अध्याय", "注", "章", "장"]
    }
}
