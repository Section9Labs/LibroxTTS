import CryptoKit
import Foundation

/// Private research evidence: source-grounded roles, never inferred emotion.
public struct CTRolePoolEvidence: Sendable, Codable, Equatable {
    public struct Span: Sendable, Codable, Equatable {
        public let offsetUTF16: Int
        public let lengthUTF16: Int
        public let text: String
        public let role: String
        public init(offsetUTF16: Int, lengthUTF16: Int, text: String, role: String) {
            self.offsetUTF16 = offsetUTF16; self.lengthUTF16 = lengthUTF16
            self.text = text; self.role = role
        }
    }
    public let binding: CTTextContext.Binding
    public let spans: [Span]
    public init(binding: CTTextContext.Binding, spans: [Span]) {
        self.binding = binding; self.spans = spans
    }
    public struct Evaluation: Sendable, Codable {
        public let mask: [Float]
        public let otherDialogueIndices: [Int]
        public let narratorLexicalCount: Int
        public let disposition: String
    }
    public func evaluated(allOnesControl: Bool = false) throws -> Evaluation {
        let result = try CTRolePoolInputs(binding: binding, evidence: self, allOnesControl: allOnesControl)
        return Evaluation(mask: try result.tensor.floats(), otherDialogueIndices: result.otherDialogueIndices,
            narratorLexicalCount: result.narratorLexicalCount, disposition: result.disposition)
    }
    public var identity: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "invalid" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CTRolePoolInputs {
    static let revision = "narrator-owned-second-pool-v1"
    let tensor: CTTensor
    let otherDialogueIndices: [Int]
    let narratorLexicalCount: Int
    let disposition: String

    init(binding: CTTextContext.Binding, evidence: CTRolePoolEvidence?, allOnesControl: Bool = false) throws {
        let original = try CTQuotePoolInputs(binding: binding).tensor
        func result(_ reason: String) -> CTRolePoolInputs {
            .init(tensor: original, otherDialogueIndices: [], narratorLexicalCount: 0, disposition: reason)
        }
        guard let evidence, evidence.binding == binding,
              CTTextContext.validates(binding, spokenText: binding.spokenText, language: binding.language,
                modelFingerprint: binding.modelFingerprint, styleID: binding.styleID),
              !evidence.spans.isEmpty, evidence.spans.count <= 5 else { self = result("invalid-evidence-fallback"); return }
        let source = binding.contextText as NSString
        let scalars = Array(binding.normalizedContext.unicodeScalars)
        let prefix = "<\(binding.language)>".unicodeScalars.count
        let suffix = "</\(binding.language)>".unicodeScalars.count
        let spoken = Set(binding.gatherIndices)
        var cursor = 0, spokenMatches = 0, other = Set<Int>(), narrator = Set<Int>()
        for span in evidence.spans {
            guard ["dialogue", "narration", "attribution"].contains(span.role),
                  span.offsetUTF16 >= cursor, span.lengthUTF16 > 0,
                  span.offsetUTF16 <= source.length, span.lengthUTF16 <= source.length - span.offsetUTF16,
                  source.substring(with: NSRange(location: cursor, length: span.offsetUTF16 - cursor)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.substring(with: NSRange(location: span.offsetUTF16, length: span.lengthUTF16)) == span.text,
                  let mapped = try? CTTextContext.bind(contextText: binding.contextText,
                    spokenRange: NSRange(location: span.offsetUTF16, length: span.lengthUTF16), spokenText: span.text,
                    language: binding.language, modelFingerprint: binding.modelFingerprint, styleID: binding.styleID),
                  mapped.normalizedContext == binding.normalizedContext else { self = result("invalid-mapping-fallback"); return }
            cursor = span.offsetUTF16 + span.lengthUTF16
            let indices = Set(mapped.gatherIndices.filter { $0 >= prefix && $0 < scalars.count - suffix })
            if span.offsetUTF16 == binding.spokenOffsetUTF16 && span.lengthUTF16 == binding.spokenLengthUTF16 {
                guard span.role == "dialogue", mapped.gatherIndices == binding.gatherIndices else { self = result("invalid-target-fallback"); return }
                spokenMatches += 1
            } else if span.role == "dialogue" { other.formUnion(indices) }
            else { narrator.formUnion(indices) }
        }
        guard spokenMatches == 1, source.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              other.isDisjoint(with: spoken) else { self = result("invalid-coverage-fallback"); return }
        let lexical = CharacterSet.letters.union(.decimalDigits)
        let count = narrator.filter { !spoken.contains($0) && lexical.contains(scalars[$0]) }.count
        guard count > 0 else { self = result("no-narrator-lexical-fallback"); return }
        var values = try original.floats()
        let removed = other.filter { values[$0] == 1 }.sorted()
        if !allOnesControl { for index in removed { values[index] = 0 } }
        self.init(tensor: try CTTensor(values, shape: original.shape), otherDialogueIndices: removed,
                  narratorLexicalCount: count, disposition: allOnesControl ? "all-ones-control" : (removed.isEmpty ? "no-other-dialogue" : "active"))
    }
    private init(tensor: CTTensor, otherDialogueIndices: [Int], narratorLexicalCount: Int, disposition: String) {
        self.tensor = tensor; self.otherDialogueIndices = otherDialogueIndices
        self.narratorLexicalCount = narratorLexicalCount; self.disposition = disposition
    }
}
