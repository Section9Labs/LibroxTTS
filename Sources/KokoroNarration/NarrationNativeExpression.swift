import Foundation
import LibroxCTNative
import KokoroPronunciation

/// Shared playback/prewarm/preview preparation for the approved expression bundle.
/// Dialogue alone receives context. Every binding retains at most two neighboring
/// units on each side and never crosses a paragraph; the engine stores no book state.
public enum NarrationNativeExpression {
    public static let revision = CTApprovedExpression.identity

    public static func prepare(units: [BookNarrationUnit], source: String,
                               decisions: [SpeakerDecision]) throws -> [BookNarrationUnit] {
        let fingerprint = try CTTextContext.modelFingerprint()
        var result = units
        for index in result.indices {
            try Task.checkCancellation()
            result[index].nativeExpression = nil
            result[index].nativeTextContext = nil
            guard units[index].role == .dialogue,
                  let voice = NarrationModel.plus.nativeVoices.first(where: { $0.id == units[index].voiceID }) else { continue }
            // Mapping failures deliberately preserve isolated audio. They are not
            // evidence that a different span or speaker can safely be substituted.
            do {
                let binding = try NarrationTextContext.surrounding(units, index: index, source: source,
                    language: voice.language, modelFingerprint: fingerprint, styleID: voice.styleID)
                let roles = try roleEvidence(units: units, index: index, source: source, binding: binding)
                let reporting = NarrationReportingContext.evidence(units: units, index: index, source: source,
                    roleEvidence: roles, decisions: decisions)
                result[index].nativeTextContext = binding
                result[index].nativeExpression = try CTExpressionInput(roles: roles, reporting: reporting)
            } catch is CancellationError { throw CancellationError() }
            catch { result[index].nativeTextContext = nil }
        }
        return result
    }

    public static func roleEvidence(units: [BookNarrationUnit], index: Int, source: String,
                                     binding: CTTextContext.Binding) throws -> CTRolePoolEvidence {
        let original = source as NSString
        var matches: [[CTRolePoolEvidence.Span]] = []
        for low in max(0, index - 2)...index {
            for high in index...min(units.count - 1, index + 2) {
                var assembled = "", spans: [CTRolePoolEvidence.Span] = [], selectedOffset = -1, valid = true
                for position in low...high {
                    let unit = units[position]
                    guard unit.range.location >= 0, unit.range.length > 0,
                          unit.range.location <= original.length, unit.range.length <= original.length - unit.range.location,
                          original.substring(with: unit.range) == unit.text else { valid = false; break }
                    if position > low {
                        let priorEnd = NSMaxRange(units[position - 1].range)
                        guard priorEnd <= unit.range.location else { valid = false; break }
                        let gap = original.substring(with: NSRange(location: priorEnd, length: unit.range.location - priorEnd))
                        guard !gap.contains(where: \.isNewline) else { valid = false; break }
                        assembled += gap
                    }
                    if position == index { selectedOffset = assembled.utf16.count }
                    spans.append(.init(offsetUTF16: assembled.utf16.count, lengthUTF16: unit.synthesisText.utf16.count,
                        text: unit.synthesisText, role: unit.role.rawValue))
                    assembled += unit.synthesisText
                }
                if valid, assembled == binding.contextText, selectedOffset == binding.spokenOffsetUTF16 {
                    matches.append(spans)
                }
            }
        }
        guard matches.count == 1, let spans = matches.first else { throw CTError.invalidTensor("ambiguous role window") }
        return CTRolePoolEvidence(binding: binding, spans: spans)
    }

}
