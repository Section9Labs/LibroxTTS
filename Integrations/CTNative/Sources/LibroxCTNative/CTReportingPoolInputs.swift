import CryptoKit
import Foundation

/// Private diagnostic evidence from the SDK's existing attribution and sentence parser.
/// Offsets address the unchanged bound context; no acoustic thresholds participate.
public struct CTReportingPoolEvidence: Sendable, Codable, Equatable {
    public static let revision = "attached-reporting-second-pool-v1"
    public struct Sentence: Sendable, Codable, Equatable {
        public let offsetUTF16: Int
        public let lengthUTF16: Int
        public let text: String
        public init(offsetUTF16: Int, lengthUTF16: Int, text: String) {
            self.offsetUTF16 = offsetUTF16; self.lengthUTF16 = lengthUTF16; self.text = text
        }
    }
    public struct Attachment: Sendable, Codable, Equatable {
        public let decisionOffsetUTF16: Int
        public let decisionLengthUTF16: Int
        public let decisionReason: String
        public let decisionSpeakerID: String
        public let literalEvidence: String
        public let classifierReason: String
        public let spanSpeakerIDs: [String?]
        /// Exact sentence ranges within the following complete narration span.
        public let sentences: [Sentence]
        public init(decisionOffsetUTF16: Int, decisionLengthUTF16: Int, decisionReason: String,
                    decisionSpeakerID: String, literalEvidence: String, classifierReason: String,
                    spanSpeakerIDs: [String?], sentences: [Sentence]) {
            self.decisionOffsetUTF16 = decisionOffsetUTF16; self.decisionLengthUTF16 = decisionLengthUTF16
            self.decisionReason = decisionReason; self.decisionSpeakerID = decisionSpeakerID
            self.literalEvidence = literalEvidence; self.classifierReason = classifierReason
            self.spanSpeakerIDs = spanSpeakerIDs; self.sentences = sentences
        }
    }
    public let binding: CTTextContext.Binding
    public let attachment: Attachment?
    public let disposition: String
    public init(binding: CTTextContext.Binding, attachment: Attachment? = nil, disposition: String) {
        self.binding = binding; self.attachment = attachment; self.disposition = disposition
    }
    public struct Evaluation: Sendable, Codable {
        public let mask: [Float]
        public let removedIndices: [Int]
        public let retainedNarratorLexicalCount: Int
        public let disposition: String
    }
    public func evaluated(roleEvidence: CTRolePoolEvidence, allKeepControl: Bool = false) throws -> Evaluation {
        let input = try CTReportingPoolInputs(binding: binding, roleEvidence: roleEvidence,
                                             evidence: self, allKeepControl: allKeepControl)
        return Evaluation(mask: try input.tensor.floats(), removedIndices: input.removedIndices,
            retainedNarratorLexicalCount: input.retainedNarratorLexicalCount, disposition: input.disposition)
    }
    public var identity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CTReportingPoolInputs {
    let tensor: CTTensor
    let removedIndices: [Int]
    let retainedNarratorLexicalCount: Int
    let disposition: String

    init(binding: CTTextContext.Binding, roleEvidence: CTRolePoolEvidence?,
         evidence: CTReportingPoolEvidence?, allKeepControl: Bool = false) throws {
        // Every control/fallback starts from real06, never the03 quote-only pool.
        let base = try CTRolePoolInputs(binding: binding, evidence: roleEvidence)
        func fallback(_ reason: String) -> Self {
            .init(tensor: base.tensor, removedIndices: [], retainedNarratorLexicalCount: base.narratorLexicalCount,
                  disposition: reason)
        }
        if allKeepControl { self = fallback("all-keep-control"); return }
        guard ["active", "no-other-dialogue"].contains(base.disposition),
              let roleEvidence, let evidence, evidence.binding == binding, roleEvidence.binding == binding,
              evidence.disposition == "validated-reporting-boundary", let attachment = evidence.attachment else {
            self = fallback(evidence?.disposition ?? "missing-reporting-evidence-fallback"); return
        }
        let spans = roleEvidence.spans
        guard let target = spans.firstIndex(where: { $0.offsetUTF16 == binding.spokenOffsetUTF16 && $0.lengthUTF16 == binding.spokenLengthUTF16 }),
              target + 1 < spans.count, spans[target].role == "dialogue", spans[target + 1].role == "narration",
              attachment.spanSpeakerIDs.count == spans.count,
              !attachment.decisionSpeakerID.isEmpty,
              attachment.spanSpeakerIDs[target] == attachment.decisionSpeakerID,
              attachment.decisionOffsetUTF16 == binding.spokenOffsetUTF16,
              attachment.decisionLengthUTF16 == binding.spokenLengthUTF16,
              attachment.decisionReason == "explicitName", attachment.classifierReason == "quoteToReportingClause",
              !attachment.literalEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self = fallback("invalid-reporting-ownership-fallback"); return
        }
        if let next = spans.indices.dropFirst(target + 2).first(where: { spans[$0].role == "dialogue" }),
           attachment.spanSpeakerIDs[next] != attachment.decisionSpeakerID {
            self = fallback("next-speaker-change-fallback"); return
        }
        let reporting = spans[target + 1]
        let source = binding.contextText as NSString
        let targetEnd = binding.spokenOffsetUTF16 + binding.spokenLengthUTF16
        guard reporting.offsetUTF16 >= targetEnd,
              !source.substring(with: NSRange(location: targetEnd, length: reporting.offsetUTF16 - targetEnd)).contains(where: \.isNewline),
              !reporting.text.contains(where: \.isNewline), !attachment.sentences.isEmpty else {
            self = fallback("invalid-reporting-boundary-fallback"); return
        }
        let reportText = reporting.text as NSString
        var cursor = 0
        for sentence in attachment.sentences {
            guard sentence.offsetUTF16 >= cursor, sentence.lengthUTF16 > 0,
                  sentence.offsetUTF16 <= reportText.length, sentence.lengthUTF16 <= reportText.length - sentence.offsetUTF16,
                  Range(NSRange(location: sentence.offsetUTF16, length: sentence.lengthUTF16), in: reporting.text) != nil,
                  reportText.substring(with: NSRange(location: cursor, length: sentence.offsetUTF16 - cursor)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  reportText.substring(with: NSRange(location: sentence.offsetUTF16, length: sentence.lengthUTF16)) == sentence.text else {
                self = fallback("invalid-reporting-sentences-fallback"); return
            }
            cursor = sentence.offsetUTF16 + sentence.lengthUTF16
        }
        guard reportText.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = attachment.sentences.first,
              first.text.components(separatedBy: attachment.literalEvidence).count == 2 else {
            self = fallback("invalid-reporting-evidence-fallback"); return
        }
        let ending = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’»)]}」』"))
        guard !ending.hasSuffix("..."), !ending.hasSuffix("…"),
              ending.last.map({ ".!?。！？؟।॥".contains($0) }) == true else {
            self = fallback("incomplete-reporting-sentence-fallback"); return
        }
        let cutoff = reporting.offsetUTF16 + first.offsetUTF16 + first.lengthUTF16
        let scalars = Array(binding.normalizedContext.unicodeScalars)
        let prefix = "<\(binding.language)>".unicodeScalars.count
        let suffix = "</\(binding.language)>".unicodeScalars.count
        let lexical = CharacterSet.letters.union(.decimalDigits)
        var remove = Set<Int>(), narrator = Set<Int>()
        for span in spans where span.role == "narration" || span.role == "attribution" {
            guard let mapped = try? CTTextContext.bind(contextText: binding.contextText,
                spokenRange: NSRange(location: span.offsetUTF16, length: span.lengthUTF16), spokenText: span.text,
                language: binding.language, modelFingerprint: binding.modelFingerprint, styleID: binding.styleID),
                  mapped.normalizedContext == binding.normalizedContext else {
                self = fallback("invalid-reporting-token-map-fallback"); return
            }
            narrator.formUnion(mapped.gatherIndices.filter { $0 >= prefix && $0 < scalars.count - suffix })
            let start = max(cutoff, span.offsetUTF16), end = span.offsetUTF16 + span.lengthUTF16
            guard start < end else { continue }
            let range = NSRange(location: start, length: end - start), text = source.substring(with: range)
            guard text.unicodeScalars.contains(where: { lexical.contains($0) }) else { continue }
            guard let later = try? CTTextContext.bind(contextText: binding.contextText, spokenRange: range,
                spokenText: text, language: binding.language, modelFingerprint: binding.modelFingerprint, styleID: binding.styleID),
                  later.normalizedContext == binding.normalizedContext else {
                self = fallback("invalid-reporting-token-map-fallback"); return
            }
            remove.formUnion(later.gatherIndices.filter { $0 >= prefix && $0 < scalars.count - suffix })
        }
        var values = try base.tensor.floats()
        let removed = remove.filter { values[$0] == 1 }.sorted()
        let retained = narrator.filter { !remove.contains($0) && values[$0] == 1 && lexical.contains(scalars[$0]) }.count
        guard retained > 0, removed.contains(where: { lexical.contains(scalars[$0]) }) else {
            self = fallback("no-later-narration-fallback"); return
        }
        guard Set(removed).isDisjoint(with: binding.gatherIndices) else {
            self = fallback("reporting-overlaps-spoken-fallback"); return
        }
        for index in removed { values[index] = 0 }
        self.init(tensor: try CTTensor(values, shape: base.tensor.shape), removedIndices: removed,
                  retainedNarratorLexicalCount: retained, disposition: "active")
    }
    private init(tensor: CTTensor, removedIndices: [Int], retainedNarratorLexicalCount: Int, disposition: String) {
        self.tensor = tensor; self.removedIndices = removedIndices
        self.retainedNarratorLexicalCount = retainedNarratorLexicalCount; self.disposition = disposition
    }
}
