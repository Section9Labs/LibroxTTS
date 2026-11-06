// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog

/// Listening candidates. No change to the current app's default conditioning.
public enum NarrationStylePolicy: String, Sendable, CaseIterable {
    case fixed, length, boundedLength
    public func row(phonemeCount: Int) -> Int {
        switch self {
        case .fixed: 158
        case .length: min(510, max(1, phonemeCount))
        case .boundedLength: min(240, max(80, phonemeCount))
        }
    }
}

/// Semantic proposal for a local pitch excursion, not a timing/alignment claim.
public struct NarrationFocus: Sendable, Equatable {
    public let phonemeRange: Range<Int>
    public let semitones: Float
    public let reason: String
}

public enum EnhancedNarrationDelivery {
    public static let revision = "enhanced-listening-candidate-2"
    /// Audition-only context for a tiny stage-dialogue turn. Reuses source text
    /// already meant to be spoken; never invents carrier words or splices PCM.
    /// Different rendering voices, non-adjacent ranges and oversized groups
    /// remain separate. The last turn keeps its speaker identity at the exit.
    public static func shortSpanishContextUnits(_ units: [BookNarrationUnit]) -> [BookNarrationUnit] {
        var result: [BookNarrationUnit] = []
        for unit in units {
            guard Voice.named(unit.voiceID)?.language == .spanish,
                  unit.role == .dialogue, unit.text.contains("!"),
                  unit.text.split(whereSeparator: { $0.isWhitespace }).count == 1,
                  (1..<20).contains(unit.phonemes.unicodeScalars.count),
                  let label = result.last, label.role == .attribution,
                  label.voiceID == unit.voiceID,
                  NSMaxRange(label.range) == unit.range.location,
                  label.phonemes.unicodeScalars.count <= 60 else {
                result.append(unit); continue
            }
            var group = [result.removeLast(), unit]
            if let context = result.last, context.role == .narration,
               context.voiceID == unit.voiceID,
               NSMaxRange(context.range) == label.range.location,
               context.phonemes.unicodeScalars.count + group.reduce(0, { $0 + $1.phonemes.unicodeScalars.count }) <= 180 {
                group.insert(result.removeLast(), at: 0)
            }
            let first = group[0]
            var merged = BookNarrationUnit(text: group.map(\.text).joined(),
                range: .init(location: first.range.location, length: NSMaxRange(unit.range) - first.range.location),
                voiceID: unit.voiceID, phonemes: group.map(\.phonemes).joined(), boundaryAfter: unit.boundaryAfter)
            merged.role = unit.role; merged.speakerID = unit.speakerID
            merged.pronunciationDiagnostics = group.flatMap(\.pronunciationDiagnostics)
            result.append(merged)
        }
        return result
    }
    /// Opt-in short-Spanish audition. Keep the speaker turn and its phonemes
    /// intact; only substitute a reference embedding for very short dialogue.
    /// This does not add context tokens or stretch the generated waveform.
    public static func shortSpanishStyleRow(for unit: BookNarrationUnit, reference: Int = 80) -> Int {
        let count = unit.phonemes.unicodeScalars.count
        let original = NarrationStylePolicy.length.row(phonemeCount: count)
        guard Voice.named(unit.voiceID)?.language == .spanish,
              unit.role == .dialogue, (1..<20).contains(count),
              unit.phonemes.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }),
              (20...510).contains(reference) else { return original }
        return reference
    }

    /// Audition-only emphasis for a complete one-word Spanish exclamation.
    /// Punctuation supplies prominence, not an anger or shouting diagnosis.
    /// Stress is taken from the actual phone string; never guess from spelling.
    public static func shortSpanishExclamationFocus(for unit: BookNarrationUnit) -> [NarrationFocus] {
        guard Voice.named(unit.voiceID)?.language == .spanish, unit.role == .dialogue,
              unit.text.unicodeScalars.count <= 80,
              unit.text.contains("!"), !unit.text.contains("?"),
              unit.text.split(whereSeparator: { $0.isWhitespace }).count == 1 else { return [] }
        let act = NarrationExpressionLexicon.analyze(text: unit.text, voiceID: unit.voiceID)
        guard act.terminal == .exclamation, ![.reassurance, .hesitation].contains(act.act) else { return [] }
        let phones = Array(unit.phonemes.unicodeScalars)
        let words = stressedWords(phones, in: 0..<phones.count)
        guard words.count == 1, let word = words.first,
              phones.filter({ $0 == "ˈ" }).count == 1,
              let stress = phones.indices.first(where: { phones[$0] == "ˈ" }),
              let nucleus = ((stress + 1)..<word.upperBound).first(where: { "aeiou".unicodeScalars.contains(phones[$0]) }) else { return [] }
        var result: [NarrationFocus] = [.init(phonemeRange: nucleus..<(nucleus + 1), semitones: 1.3,
                                            reason: "spanish-exclamation-stressed-vowel")]
        if let tail = phones.indices.last(where: { "aeiou".unicodeScalars.contains(phones[$0]) }), tail > nucleus {
            result.append(.init(phonemeRange: tail..<(tail + 1), semitones: -0.65,
                                reason: "spanish-exclamation-light-ending"))
        }
        return result
    }
    /// Small local hypotheses only for English and Spanish direct speech.
    /// Never infer anger from !, apply English contours to tonal languages,
    /// or change the speed. Explicit questions can be localized within a turn.
    public static func focus(for unit: BookNarrationUnit) -> [NarrationFocus] {
        guard let language = Voice.named(unit.voiceID)?.language,
              [Language.english, .spanish].contains(language),
              unit.role == .dialogue, unit.text.unicodeScalars.prefix(4097).count <= 4096,
              (1...510).contains(unit.phonemes.unicodeScalars.count) else { return [] }
        let phones = Array(unit.phonemes.unicodeScalars)
        let source = Array(unit.text.unicodeScalars)
        let questionEnds = source.indices.filter { source[$0] == "?" }
        let phoneEnds = phones.indices.filter { phones[$0] == "?" }
        var result: [NarrationFocus] = []
        // Align only explicit question punctuation in order. Never estimate text
        // characters as audio timestamps; actual token durations map the result.
        if questionEnds.count == phoneEnds.count, questionEnds.count <= 8 {
            for (sourceEnd, phoneEnd) in zip(questionEnds, phoneEnds) {
                var sourceStart = sourceEnd
                while sourceStart > 0, !".?!…:;".unicodeScalars.contains(source[sourceStart - 1]), source[sourceStart - 1] != "¿" { sourceStart -= 1 }
                if sourceStart > 0, source[sourceStart - 1] == "¿" {
                    var prefixStart = sourceStart - 1
                    while prefixStart > 0, !".?!…:;".unicodeScalars.contains(source[prefixStart - 1]) { prefixStart -= 1 }
                    // Text before an opening question with no matching phoneme
                    // delimiter makes the first-word alignment uncertain.
                    if source[prefixStart..<(sourceStart - 1)].contains(where: { CharacterSet.letters.contains($0) }) { continue }
                }
                var phoneStart = phoneEnd
                while phoneStart > 0, !".?!…:;".unicodeScalars.contains(phones[phoneStart - 1]) { phoneStart -= 1 }
                guard sourceStart < sourceEnd, phoneStart < phoneEnd else { continue }
                var fragment = String(String.UnicodeScalarView(source[sourceStart...sourceEnd]))
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "—–¿\"“”«»")))
                if language == .spanish {
                    // Discourse particles do not turn an information question
                    // into an unspecified one. This changes analysis only.
                    fragment = fragment.replacingOccurrences(of: #"(?i)^(?:(?:pero|y|pues|entonces)[ ,]+){1,2}"#, with: "", options: .regularExpression)
                }
                let evidence = NarrationProsody.analyze(text: fragment, voiceID: unit.voiceID)
                let words = stressedWords(phones, in: phoneStart..<phoneEnd)
                guard let last = words.last else { continue }
                switch evidence.questionKind {
                case .yesNo:
                    result.append(.init(phonemeRange: last, semitones: 0.65, reason: "polar-question-local-excursion"))
                case .informationSeeking:
                    let first = words.first { range in
                        let word = String(String.UnicodeScalarView(phones[range])).replacingOccurrences(of: "ˈ", with: "")
                        return !["i", "peɾo", "pwes"].contains(word)
                    }
                    if let first { result.append(.init(phonemeRange: first, semitones: 0.5, reason: "question-word-focus")) }
                default: break // Tags, alternatives and rhetorical/echo intent are uncertain.
                }
            }
        }
        let act = unit.speechAct ?? NarrationExpressionLexicon.analyze(text: unit.text, voiceID: unit.voiceID)
        if act.prefersStandaloneUnit, act.terminal == .exclamation,
           [.interruption, .urgentCommand, .surprise].contains(act.act),
           let first = stressedWords(phones, in: 0..<phones.count).first {
            result.append(.init(phonemeRange: first, semitones: 0.8, reason: "explicit-short-act-focus"))
        }
        return result
    }

    private static func stressedWords(_ phones: [Unicode.Scalar], in range: Range<Int>) -> [Range<Int>] {
        func isPhone(_ c: Unicode.Scalar) -> Bool {
            c == "ˈ" || c == "ˌ" || CharacterSet.letters.contains(c)
        }
        var words: [Range<Int>] = []; var start: Int?
        for i in range.lowerBound...range.upperBound {
            if i < range.upperBound, isPhone(phones[i]) { if start == nil { start = i } }
            else if let begin = start { words.append(begin..<i); start = nil }
        }
        return words.filter { phones[$0].contains("ˈ") }

    }
}
