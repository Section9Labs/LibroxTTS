import Foundation
import Testing
@testable import LibroxCTNative

private func roleFixture(_ parts: [(String, String)], spokenIndex: Int, language: String = "en") throws -> CTRolePoolEvidence {
    var text = "", spans: [CTRolePoolEvidence.Span] = []
    for (part, role) in parts {
        if !text.isEmpty { text += " " }
        spans.append(.init(offsetUTF16: text.utf16.count, lengthUTF16: part.utf16.count, text: part, role: role))
        text += part
    }
    let selected = spans[spokenIndex]
    let binding = try CTTextContext.bind(contextText: text, spokenRange: .init(location: selected.offsetUTF16, length: selected.lengthUTF16),
        spokenText: selected.text, language: language, modelFingerprint: "fixture", styleID: "F1")
    return .init(binding: binding, spans: spans)
}

@Test func rolePoolMapsRepeatedQuotesAndKeepsNarratorTitle() throws {
    let evidence = try roleFixture([("\"Wait here.\"", "dialogue"), ("She closed the book called \"Quiet Water\".", "narration"), ("\"Wait here.\"", "dialogue")], spokenIndex: 2)
    let result = try evidence.evaluated(), control = try evidence.evaluated(allOnesControl: true)
    #expect(result.disposition == "active")
    #expect(!result.otherDialogueIndices.isEmpty)
    #expect(try control.mask == CTQuotePoolInputs(binding: evidence.binding).tensor.floats())
    let scalars = Array(evidence.binding.normalizedContext.unicodeScalars)
    let retained = String(String.UnicodeScalarView(result.mask.indices.filter { result.mask[$0] == 1 }.map { scalars[$0] }))
    #expect(retained.contains("Quiet Water"))
    #expect(!retained.contains("Wait here"))
    #expect(result.otherDialogueIndices.allSatisfy { !evidence.binding.gatherIndices.contains($0) })
}

@Test func rolePoolNoNarrationAndUnknownRolesFallBackExactly() throws {
    for parts in [[("\"Wait.\"", "dialogue"), ("\"No.\"", "dialogue")],
                  [("She waited.", "unknown"), ("\"No.\"", "dialogue")]] {
        let e = try roleFixture(parts, spokenIndex: 1)
        let input = try CTRolePoolInputs(binding: e.binding, evidence: e)
        #expect(input.disposition.contains("fallback"))
        #expect(try input.tensor.data == CTQuotePoolInputs(binding: e.binding).tensor.data)
    }
}

@Test func rolePoolSingleQuoteIdentityAndTamperedEvidence() throws {
    let e = try roleFixture([("She waited.", "narration"), ("\"Come in.\"", "dialogue")], spokenIndex: 1)
    #expect(try e.evaluated().disposition == "no-other-dialogue")
    let altered = CTRolePoolEvidence(binding: e.binding, spans: [.init(offsetUTF16: 0, lengthUTF16: 1, text: "x", role: "dialogue")])
    #expect(try altered.evaluated().disposition.contains("fallback"))
    #expect(e.identity != altered.identity)
    let empty = CTContextStyleDiagnostic.Configuration(directory: URL(fileURLWithPath: "/tmp"), manifestSHA256: "manifest", carryMode: .linearTwoStep)
    let first = CTContextStyleDiagnostic.Configuration(directory: URL(fileURLWithPath: "/tmp"), manifestSHA256: "manifest", carryMode: .linearTwoStep, roleEvidence: [e.binding.renderCacheKey: e])
    let second = CTContextStyleDiagnostic.Configuration(directory: URL(fileURLWithPath: "/tmp"), manifestSHA256: "manifest", carryMode: .linearTwoStep, roleEvidence: [e.binding.renderCacheKey: altered])
    #expect(empty.diagnosticIdentity == "manifest:late-context-residual-linear2-v1:linear-two-step")
    #expect(first.diagnosticIdentity != second.diagnosticIdentity)
}

@Test func rolePoolNormalizedSpanishAndUnicodeMapping() throws {
    let e = try roleFixture([("«¡Sí!»,", "dialogue"), ("María miró el café.", "narration"), ("«Volveré mañana». ", "dialogue")], spokenIndex: 2, language: "es")
    let result = try e.evaluated()
    #expect(result.disposition == "active")
    #expect(result.narratorLexicalCount > 0)
    #expect(!result.otherDialogueIndices.isEmpty)
}

@Test func rolePoolDecomposedAccentAndInvalidUnicodeBoundary() throws {
    let e = try roleFixture([("«¡Sí!»,", "dialogue"), ("Mari\u{301}a sonrió.", "narration"), ("«Ven aquí».", "dialogue")], spokenIndex: 2, language: "es")
    #expect(try e.evaluated().disposition == "active")
    let emoji = try roleFixture([("😀 She waited.", "narration"), ("\"Come in.\"", "dialogue")], spokenIndex: 1)
    let broken = CTRolePoolEvidence(binding: emoji.binding, spans: [
        .init(offsetUTF16: 1, lengthUTF16: 1, text: "x", role: "narration"), emoji.spans[1]])
    #expect(try broken.evaluated().disposition.contains("fallback"))
}
