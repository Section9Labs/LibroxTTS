import Foundation
import NaturalLanguage
import KokoroPronunciation
import LibroxCTNative

/// Default-off diagnostic source evidence. Does not replan, select voices or alter audio.
public enum NarrationReportingContext {
    public static func evidence(units: [BookNarrationUnit], index: Int, source: String,
                                roleEvidence: CTRolePoolEvidence,
                                decisions: [SpeakerDecision]) -> CTReportingPoolEvidence {
        let binding = roleEvidence.binding
        func fallback(_ reason: String) -> CTReportingPoolEvidence { .init(binding: binding, disposition: reason) }
        guard ["en", "es"].contains(binding.language), units.indices.contains(index),
              units[index].role == .dialogue, let speaker = units[index].speakerID, !speaker.isEmpty,
              let target = roleEvidence.spans.firstIndex(where: {
                  $0.offsetUTF16 == binding.spokenOffsetUTF16 && $0.lengthUTF16 == binding.spokenLengthUTF16
              }), target + 1 < roleEvidence.spans.count else { return fallback("missing-reporting-span-fallback") }
        let unit = units[index], spans = roleEvidence.spans, original = source as NSString
        let origin = unit.range.location - binding.spokenOffsetUTF16
        var mapped: [BookNarrationUnit] = []
        for span in spans {
            let range = NSRange(location: origin + span.offsetUTF16, length: span.lengthUTF16)
            guard range.location >= 0, range.length > 0, range.location <= original.length,
                  range.length <= original.length - range.location,
                  original.substring(with: range) == span.text,
                  let prepared = units.first(where: { $0.range == range }),
                  prepared.text == span.text, prepared.synthesisText == span.text,
                  prepared.role.rawValue == span.role else { return fallback("reporting-source-mapping-fallback") }
            mapped.append(prepared)
        }
        let matches = decisions.filter { $0.offset == unit.range.location && $0.length == unit.range.length }
        guard matches.count == 1, let decision = matches.first, decision.reason == .explicitName,
              decision.speakerID == speaker, let literal = decision.evidence, !literal.isEmpty,
              mapped[target + 1].role == .narration else { return fallback("ambiguous-reporting-attribution-fallback") }
        if let next = mapped.dropFirst(target + 2).first(where: { $0.role == .dialogue }), next.speakerID != speaker {
            return fallback("next-speaker-change-fallback")
        }
        let following = mapped[target + 1]
        let gapRange = NSRange(location: NSMaxRange(unit.range), length: following.range.location - NSMaxRange(unit.range))
        guard gapRange.length >= 0 else { return fallback("reporting-source-mapping-fallback") }
        let gap = original.substring(with: gapRange)
        guard gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !gap.contains(where: \.isNewline), !following.text.contains(where: \.isNewline) else {
            return fallback("reporting-paragraph-fallback")
        }
        let classification = DialogueTiming.classify(.init(previousText: unit.text, nextText: following.text,
            previousSpeakerID: speaker, previousRole: .dialogue, nextRole: .narration,
            sourceGap: gap, languageCode: binding.language))
        guard classification.reason == .quoteToReportingClause else { return fallback("unattached-reporting-fallback") }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(NLLanguage(rawValue: binding.language)); tokenizer.string = following.text
        var sentences: [CTReportingPoolEvidence.Sentence] = []
        tokenizer.enumerateTokens(in: following.text.startIndex..<following.text.endIndex) { range, _ in
            let ns = NSRange(range, in: following.text)
            sentences.append(.init(offsetUTF16: ns.location, lengthUTF16: ns.length, text: String(following.text[range])))
            return true
        }
        guard let first = sentences.first, first.text.components(separatedBy: literal).count == 2 else {
            return fallback("reporting-evidence-outside-first-sentence-fallback")
        }
        return .init(binding: binding, attachment: .init(decisionOffsetUTF16: decision.offset - origin,
            decisionLengthUTF16: decision.length, decisionReason: decision.reason.rawValue,
            decisionSpeakerID: speaker, literalEvidence: literal, classifierReason: classification.reason.rawValue,
            spanSpeakerIDs: mapped.map(\.speakerID), sentences: sentences), disposition: "validated-reporting-boundary")
    }
}
