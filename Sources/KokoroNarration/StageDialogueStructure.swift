// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroPronunciation

/// A source-grounded dialogue interval supplied by the book's existing attribution
/// pass. UTF-16 offsets refer to the unchanged chapter, never normalized speech.
public struct StageDialogueRange: Sendable, Equatable {
    public let range: NSRange
    public let speakerID: String?
    public init(range: NSRange, speakerID: String? = nil) {
        self.range = range; self.speakerID = speakerID
    }
}

public enum StageDialogueRole: String, Sendable, Codable {
    case narration, dialogue, stageDirection, speakerLabel
}

public struct StageDialogueSpan: Sendable, Equatable {
    public let range: NSRange
    public let text: String
    public let role: StageDialogueRole
    /// Actual character only for dialogue. Labels and directions use narrator audio.
    public let speakerID: String?
    /// Ownership metadata, not an instruction to render a direction as a character.
    public let associatedSpeakerID: String?
}

public enum StageDialogueStatus: String, Sendable, Codable {
    case parsed, unsupportedLanguage, inputLimit, invalidDialogueRanges, outputLimit
}

public struct StageDialogueResult: Sendable, Equatable {
    public let spans: [StageDialogueSpan]
    public let status: StageDialogueStatus
    public var accepted: Bool { status == .parsed }
}

/// Bounded theatrical structure with localized direction cues. No speaker
/// alternation, sentiment, voice assignment or audio controls. Every result
/// covers the original text exactly once; uncertain parentheticals stay spoken.
public enum StageDialogueStructure {
    public static let revision = "stage-dialogue-2"
    public static let maximumUTF16Length = 16_384
    public static let maximumRanges = 2_048
    public static let maximumSpans = 8_192
    public static let maximumDirectionUTF16Length = 1_024

    public static func parse(_ source: String, languageCode: String,
                             establishedDialogue: [StageDialogueRange] = [],
                             knownSpeakerLabels: [String: String] = [:]) -> StageDialogueResult {
        let ns = source as NSString
        func fallback(_ status: StageDialogueStatus) -> StageDialogueResult {
            .init(spans: source.isEmpty ? [] : [.init(range: NSRange(location: 0, length: ns.length),
                text: source, role: .narration, speakerID: nil, associatedSpeakerID: nil)], status: status)
        }
        let language = String(languageCode.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        guard NarrationLanguageRules.profiles[language] != nil else {
            return fallback(.unsupportedLanguage)
        }
        guard ns.length <= maximumUTF16Length, establishedDialogue.count <= maximumRanges,
              knownSpeakerLabels.count <= 256 else { return fallback(.inputLimit) }
        let seeds = establishedDialogue.sorted { $0.range.location < $1.range.location }
        var lastEnd = 0
        for seed in seeds {
            guard seed.range.location >= lastEnd, seed.range.length > 0,
                  seed.range.location <= ns.length, seed.range.length <= ns.length - seed.range.location,
                  Range(seed.range, in: source) != nil,
                  isUTF16Boundary(seed.range.location, in: ns),
                  isUTF16Boundary(NSMaxRange(seed.range), in: ns),
                  seed.speakerID.map({ !$0.isEmpty && $0.utf16.count <= 128 }) ?? true else {
                return fallback(.invalidDialogueRanges)
            }
            lastEnd = NSMaxRange(seed.range)
        }
        var known: [String: String] = [:]
        for (label, id) in knownSpeakerLabels where label.utf16.count <= 96 && !id.isEmpty && id.utf16.count <= 128 {
            known[canonical(label)] = id
        }
        let labels = explicitLabels(in: source, known: known)
        var boundaries = Set([0, ns.length])
        for seed in seeds { boundaries.insert(seed.range.location); boundaries.insert(NSMaxRange(seed.range)) }
        for label in labels {
            boundaries.insert(label.range.location); boundaries.insert(NSMaxRange(label.range)); boundaries.insert(label.scopeEnd)
        }
        let sorted = boundaries.sorted()
        var spans: [StageDialogueSpan] = []
        var seedIndex = 0, labelIndex = 0
        func append(_ range: NSRange, role: StageDialogueRole, speaker: String?, owner: String?) {
            guard range.length > 0 else { return }
            let value = ns.substring(with: range)
            if let previous = spans.last, previous.role == role, previous.speakerID == speaker,
               previous.associatedSpeakerID == owner, NSMaxRange(previous.range) == range.location {
                spans[spans.count - 1] = .init(range: NSRange(location: previous.range.location,
                    length: previous.range.length + range.length), text: previous.text + value,
                    role: role, speakerID: speaker, associatedSpeakerID: owner)
            } else {
                spans.append(.init(range: range, text: value, role: role,
                                   speakerID: speaker, associatedSpeakerID: owner))
            }
        }
        for (start, end) in zip(sorted, sorted.dropFirst()) where start < end {
            while seedIndex < seeds.count && NSMaxRange(seeds[seedIndex].range) <= start { seedIndex += 1 }
            while labelIndex < labels.count && labels[labelIndex].scopeEnd <= start { labelIndex += 1 }
            let seed = seedIndex < seeds.count && seeds[seedIndex].range.location <= start ? seeds[seedIndex] : nil
            let label = labelIndex < labels.count && labels[labelIndex].range.location <= start ? labels[labelIndex] : nil
            let range = NSRange(location: start, length: end - start)
            if let label, start < NSMaxRange(label.range) {
                append(range, role: .speakerLabel, speaker: nil, owner: label.speakerID)
            } else if label != nil || seed != nil {
                let owner = label?.speakerID ?? seed?.speakerID
                append(range, role: .dialogue, speaker: owner, owner: owner)
            } else {
                append(range, role: .narration, speaker: nil, owner: nil)
            }
        }
        // Splitting follows interval composition, so parentheses can span an
        // upstream segmentation boundary without losing a known speaker.
        var split: [StageDialogueSpan] = []
        for span in spans {
            guard span.role == .dialogue else { split.append(span); continue }
            let directions = stageDirections(in: span.text, language: language)
            var cursor = 0
            for direction in directions {
                if cursor < direction.location { split.append(subspan(span, local: NSRange(location: cursor, length: direction.location - cursor), role: .dialogue)) }
                split.append(subspan(span, local: direction, role: .stageDirection))
                cursor = NSMaxRange(direction)
            }
            if cursor < span.range.length { split.append(subspan(span, local: NSRange(location: cursor, length: span.range.length - cursor), role: .dialogue)) }
            if split.count > maximumSpans { return fallback(.outputLimit) }
        }
        guard split.count <= maximumSpans else { return fallback(.outputLimit) }
        return .init(spans: split, status: .parsed)
    }

    /// Shared book-level structure preparation. Keep established embedded
    /// speakers, source coverage and narrator-owned directions identical across
    /// phoneme and native-text adapters.
    static func parseBook(_ source: String, languageCode: String,
                          establishedDialogue: [StageDialogueRange],
                          knownSpeakerLabels: [String: String]) -> StageDialogueResult? {
        var seeds = establishedDialogue
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
        let structure = parse(source, languageCode: languageCode,
            establishedDialogue: seeds, knownSpeakerLabels: knownSpeakerLabels)
        guard structure.accepted, structure.spans.map(\.text).joined() == source else { return nil }
        let original = source as NSString
        var expectedOffset = 0
        for span in structure.spans {
            guard span.range.location == expectedOffset, span.range.length >= 0,
                  span.range.length <= original.length - expectedOffset,
                  original.substring(with: span.range) == span.text else { return nil }
            expectedOffset += span.range.length
        }
        guard expectedOffset == original.length else { return nil }
        return structure
    }

    private struct Label {
        let range: NSRange
        var scopeEnd: Int
        let speakerID: String
    }

    private static func isUTF16Boundary(_ offset: Int, in text: NSString) -> Bool {
        guard offset > 0, offset < text.length else { return true }
        let previous = text.character(at: offset - 1), next = text.character(at: offset)
        return !(0xD800...0xDBFF).contains(previous) || !(0xDC00...0xDFFF).contains(next)
    }

    private static func canonical(_ label: String) -> String {
        label.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func explicitLabels(in source: String, known: [String: String]) -> [Label] {
        let ns = source as NSString
        // A period + dash is a strong theatrical convention. Plain colon/dash
        // requires a trusted registered name: ordinary headings stay narration.
        let pattern = #"^[\t ]*([\p{L}\p{M}][\p{L}\p{M}'’\-]*(?:[\t ]+[\p{L}\p{M}][\p{L}\p{M}'’\-]*){0,5})[\t ]*(\.[\t ]*[—–-]|:|[—–])[\t ]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var labels: [Label] = [], start = 0
        while start < ns.length {
            let line = ns.lineRange(for: NSRange(location: start, length: 0))
            defer { start = NSMaxRange(line) }
            let head = ns.substring(with: NSRange(location: start, length: min(line.length, 112)))
            let localLength = (head as NSString).length
            guard let match = regex.firstMatch(in: head, range: NSRange(location: 0, length: localLength)),
                  match.range.length <= 112 else { continue }
            let label = (head as NSString).substring(with: match.range(at: 1))
            let key = canonical(label)
            guard label.utf16.count <= 96, !reservedLabels.contains(key),
                  (label.first?.isUppercase == true || known[key] != nil) else { continue }
            let marker = (head as NSString).substring(with: match.range(at: 2))
            guard marker.contains(".") || known[key] != nil else { continue }
            // Label scope is a typographic paragraph. It never carries a speaker
            // through a blank paragraph, scene prose or the next unlabeled dash.
            var scopeEnd = NSMaxRange(line)
            var probe = scopeEnd
            while probe < ns.length {
                let nextLine = ns.lineRange(for: NSRange(location: probe, length: 0))
                let value = ns.substring(with: nextLine)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.first == "—" || trimmed.first == "–" { break }
                scopeEnd = NSMaxRange(nextLine); probe = scopeEnd
            }
            let id = known[key] ?? "stage-label:" + key
            labels.append(.init(range: NSRange(location: start + match.range.location, length: match.range.length), scopeEnd: scopeEnd, speakerID: id))
        }
        for index in labels.indices.dropLast() {
            labels[index].scopeEnd = min(labels[index].scopeEnd, labels[index + 1].range.location)
        }
        return labels
    }

    private static let reservedLabels: Set<String> = [
        "nota", "notas", "advertencia", "aviso", "capítulo", "capitulo", "parte", "escena", "acto",
        "resumen", "índice", "indice", "ejemplo", "introducción", "prólogo", "epílogo", "fin"
    ]

    private static func stageDirections(in text: String, language: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = [], opening: Int?, depth = 0, invalid = false
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            if c == 40 || c == 0xFF08 { // ( or full-width （
                if depth == 0 { opening = i; invalid = false }
                depth += 1
                if depth > 8 { invalid = true }
            } else if c == 41 || c == 0xFF09, depth > 0 {
                depth -= 1
                if depth == 0, let start = opening {
                    let range = NSRange(location: start, length: i - start + 1)
                    if !invalid, range.length <= maximumDirectionUTF16Length,
                       isDirectionCue(ns.substring(with: range), language: language) { ranges.append(range) }
                    opening = nil
                }
            }
        }
        return ranges
    }

    private static func isDirectionCue(_ text: String, language: String) -> Bool {
        let body = text.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.contains("\n"), !body.contains("\r") else { return false }
        if language != "es" {
            let value = body.precomposedStringWithCanonicalMapping.lowercased()
            return NarrationLanguageRules.profiles[language]?.directionCues.contains { cue in
                value == cue || value.hasPrefix(cue + " ") || value.hasPrefix(cue + ".")
                    || value.hasPrefix(cue + ",") || value.hasPrefix(cue + "。") || value.hasPrefix(cue + "।")
            } == true
        }
        guard body.first?.isUppercase == true else { return false }
        let value = body.precomposedStringWithCanonicalMapping.lowercased()
        let first = value.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        let action = ["observa", "mira", "ríe", "llora", "grita", "susurra", "señala", "entra", "sale", "pausa", "silencio"]
        if action.contains(first) { return true }
        if first.range(of: #"^\p{L}+(?:ando|iendo|yendo|ándose|iéndose|yéndose)$"#, options: .regularExpression) != nil { return true }
        let manners = ["con orgullo", "con solemnidad", "con alborozo", "con alegría", "con tristeza", "con miedo", "con ira", "con rabia", "con alivio", "con voz", "con tono", "con sorpresa", "con asombro", "con desprecio", "con impaciencia", "con calma", "sin disimular", "en voz", "aparte"]
        return manners.contains { value == $0 || value.hasPrefix($0 + " ") || value.hasPrefix($0 + ".") || value.hasPrefix($0 + ",") || value.hasPrefix($0 + ")") }
    }

    private static func subspan(_ span: StageDialogueSpan, local: NSRange, role: StageDialogueRole) -> StageDialogueSpan {
        .init(range: NSRange(location: span.range.location + local.location, length: local.length),
              text: (span.text as NSString).substring(with: local), role: role,
              speakerID: role == .dialogue ? span.speakerID : nil,
              associatedSpeakerID: span.associatedSpeakerID)
    }
}
