import Foundation
import Testing
import LibroxCTNative
@testable import KokoroNarration

private func reportingPlan(_ source: String, language: String = "en") async throws -> [(CTRolePoolEvidence, CTReportingPoolEvidence)] {
    let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "reporting-test", chapterID: "1",
        narratorVoiceID: "plus-f1-\(language)-v1", language: language, characterVoices: true)
    var result: [(CTRolePoolEvidence, CTReportingPoolEvidence)] = []
    for (index,unit) in plan.units.enumerated() where unit.role == .dialogue {
        let binding = try NarrationTextContext.surrounding(plan.units, index: index, source: source,
            language: language, modelFingerprint: "test", styleID: "F1")
        let origin = unit.range.location - binding.spokenOffsetUTF16
        let end = origin + binding.contextText.utf16.count
        let spans = plan.units.filter { $0.range.location >= origin && NSMaxRange($0.range) <= end }.map {
            CTRolePoolEvidence.Span(offsetUTF16: $0.range.location - origin, lengthUTF16: $0.range.length,
                text: $0.synthesisText, role: $0.role.rawValue)
        }
        let roles = CTRolePoolEvidence(binding: binding, spans: spans)
        result.append((roles,NarrationReportingContext.evidence(units: plan.units, index: index, source: source,
            roleEvidence: roles, decisions: plan.bookPlan?.attribution?.decisions ?? [])))
    }
    return result
}

@Test func reportingContextUsesExactSDKDecisionAndFullSentence() async throws {
    for (language,source,phrase) in [
        ("en", "Mara checked the drawer. \"It is with me,\" Mara said softly while she held the door. The window broke. \"Stay here,\" Mara said.", "softly while she held the door"),
        ("es", "Elena miró el café. \"¿Es para mí?\", dijo Elena mientras acercaba la lámpara. Entonces vio una sombra. \"Vamos los dos\", dijo Elena.", "mientras acercaba la lámpara")
    ] {
        let cases = try await reportingPlan(source, language: language)
        let first = try #require(cases.first)
        #expect(try first.1.evaluated(roleEvidence: first.0).disposition == "active")
        let attachment = try #require(first.1.attachment)
        #expect(attachment.sentences[0].text.contains(phrase))
        #expect(attachment.sentences[0].text.contains(attachment.literalEvidence))
        #expect(attachment.decisionOffsetUTF16 == first.0.binding.spokenOffsetUTF16)
        #expect(attachment.decisionLengthUTF16 == first.0.binding.spokenLengthUTF16)
        let last = try #require(cases.last)
        #expect(try last.1.evaluated(roleEvidence: last.0).mask == last.0.evaluated().mask)
    }
}

@Test func reportingContextKnownNextSpeakerDoesNotChange06() async throws {
    let cases = try await reportingPlan("\"Wait here,\" Daniel said. He looked at the door. \"I will go,\" Mara said.")
    let first = try #require(cases.first)
    #expect(first.1.disposition == "next-speaker-change-fallback")
    #expect(try first.1.evaluated(roleEvidence: first.0).mask == first.0.evaluated().mask)
}

@Test func reportingContextEllipsisAndParagraphStay06() async throws {
    for source in ["\"Wait here,\" Mara said... She looked away. \"Come in,\" Mara said.",
                   "\"Wait here,\" Mara said.\n\nShe looked away. \"Come in,\" Mara said."] {
        for (roles,evidence) in try await reportingPlan(source) {
            #expect(try evidence.evaluated(roleEvidence: roles).mask == roles.evaluated().mask)
        }
    }
}

@Test func reportingContextRepeatedQuotesUseTheirOwnDecision() async throws {
    let cases = try await reportingPlan("\"Wait here,\" Mara said. She looked at the door. \"Wait here,\" Mara said.")
    #expect(cases.count == 2)
    #expect(try cases[0].1.evaluated(roleEvidence: cases[0].0).disposition == "active")
    #expect(try cases[1].1.evaluated(roleEvidence: cases[1].0).disposition != "active")
    #expect(cases[0].1.binding.spokenOffsetUTF16 != cases[1].1.binding.spokenOffsetUTF16)
}
