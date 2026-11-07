import Foundation
import Testing
@testable import LibroxCTNative

private func reportingFixture(language: String = "en", later: String = "The window broke.",
                              ending: String = ".", nextSpeaker: String = "c1") throws -> (CTRolePoolEvidence, CTReportingPoolEvidence) {
    let quote = language == "es" ? "«¿Es para mí?»," : "\"It is with me,\""
    let prior = language == "es" ? "Elena miró el café. " : "Mara checked the drawer. "
    let first = language == "es" ? " dijo Elena mientras sostenía la lámpara\(ending) " : " Mara said softly while she held the door\(ending) "
    let report = first + later
    let parts = [(prior,"narration"), (quote,"dialogue"), (report,"narration"), (quote,"dialogue")]
    var context = "", spans: [CTRolePoolEvidence.Span] = []
    for (text,role) in parts {
        spans.append(.init(offsetUTF16: context.utf16.count, lengthUTF16: text.utf16.count, text: text, role: role))
        context += text
    }
    let binding = try CTTextContext.bind(contextText: context,
        spokenRange: NSRange(location: spans[1].offsetUTF16, length: quote.utf16.count), spokenText: quote,
        language: language, modelFingerprint: "test", styleID: "F1")
    let role = CTRolePoolEvidence(binding: binding, spans: spans)
    var sentences: [CTReportingPoolEvidence.Sentence] = [.init(offsetUTF16: 0, lengthUTF16: first.utf16.count, text: first)]
    if !later.isEmpty { sentences.append(.init(offsetUTF16: first.utf16.count, lengthUTF16: later.utf16.count, text: later)) }
    let attachment = CTReportingPoolEvidence.Attachment(decisionOffsetUTF16: spans[1].offsetUTF16,
        decisionLengthUTF16: quote.utf16.count, decisionReason: "explicitName", decisionSpeakerID: "c1",
        literalEvidence: language == "es" ? " dijo Elena" : " Mara said", classifierReason: "quoteToReportingClause",
        spanSpeakerIDs: [nil,"c1",nil,nextSpeaker], sentences: sentences)
    return (role,.init(binding: binding, attachment: attachment, disposition: "validated-reporting-boundary"))
}

@Test func reportingPoolRetainsWholeAttributionPriorNarrationAndEarlierExclusions() throws {
    for language in ["en","es"] {
        let (roles,evidence) = try reportingFixture(language: language)
        let baseline = try roles.evaluated(), active = try evidence.evaluated(roleEvidence: roles)
        #expect(active.disposition == "active")
        #expect(!active.removedIndices.isEmpty)
        #expect(baseline.mask.indices.allSatisfy { active.mask[$0] <= baseline.mask[$0] })
        let scalars = Array(evidence.binding.normalizedContext.unicodeScalars)
        let kept = String(String.UnicodeScalarView(active.mask.indices.filter { active.mask[$0] == 1 }.map { scalars[$0] }))
        #expect(kept.contains(language == "en" ? "checked the drawer" : "miró el café"))
        #expect(kept.contains(language == "en" ? "softly while she held the door" : "mientras sostenía la lámpara"))
        #expect(!kept.contains("window broke"))
        #expect(baseline.otherDialogueIndices.allSatisfy { active.mask[$0] == 0 })
        #expect(Set(active.removedIndices).isDisjoint(with: evidence.binding.gatherIndices))
    }
}

@Test func reportingPoolAllKeepIsActual06Not03() throws {
    let (role,evidence) = try reportingFixture()
    let control = try evidence.evaluated(roleEvidence: role, allKeepControl: true)
    #expect(try control.mask == role.evaluated().mask)
    #expect(try control.mask != role.evaluated(allOnesControl: true).mask)
    #expect(control.disposition == "all-keep-control")
}

@Test func reportingPoolUnchangedAndAmbiguousCasesFallBackExactly06() throws {
    let cases = [try reportingFixture(later: ""), try reportingFixture(ending: "..."),
                 try reportingFixture(nextSpeaker: "c2")]
    for (roles,evidence) in cases {
        let evaluated = try evidence.evaluated(roleEvidence: roles)
        #expect(evaluated.disposition.hasSuffix("fallback"))
        #expect(try evaluated.mask == roles.evaluated().mask)
    }
    let (role,evidence) = try reportingFixture()
    let missing = try CTReportingPoolInputs(binding: role.binding, roleEvidence: role, evidence: nil)
    #expect(try missing.tensor.floats() == role.evaluated().mask)
    let bad = CTReportingPoolEvidence(binding: evidence.binding, disposition: "ambiguous-reporting-attribution-fallback")
    #expect(try bad.evaluated(roleEvidence: role).mask == role.evaluated().mask)
}

@Test func reportingPoolRejectsWrongDecisionRangeAndBrokenSentenceCoverage() throws {
    let (roles,evidence) = try reportingFixture()
    let a = try #require(evidence.attachment)
    for wrongRange in [true,false] {
        let modified = CTReportingPoolEvidence.Attachment(decisionOffsetUTF16: a.decisionOffsetUTF16 + (wrongRange ? 1 : 0),
            decisionLengthUTF16: a.decisionLengthUTF16, decisionReason: a.decisionReason,
            decisionSpeakerID: a.decisionSpeakerID, literalEvidence: a.literalEvidence,
            classifierReason: a.classifierReason, spanSpeakerIDs: a.spanSpeakerIDs,
            sentences: wrongRange ? a.sentences : Array(a.sentences.prefix(1)))
        let bad = CTReportingPoolEvidence(binding: evidence.binding, attachment: modified, disposition: evidence.disposition)
        #expect(try bad.evaluated(roleEvidence: roles).mask == roles.evaluated().mask)
        #expect(try bad.evaluated(roleEvidence: roles).disposition.hasSuffix("fallback"))
    }
}

@Test func reportingIdentityLeavesHistorical06ExactWhenAbsent() throws {
    let (roles,evidence) = try reportingFixture()
    let old = CTContextStyleDiagnostic.Configuration(directory: URL(fileURLWithPath: "/tmp"), manifestSHA256: "m",
        carryMode: .linearTwoStep, roleEvidence: [roles.binding.renderCacheKey: roles])
    let active = CTContextStyleDiagnostic.Configuration(directory: URL(fileURLWithPath: "/tmp"), manifestSHA256: "m",
        carryMode: .linearTwoStep, roleEvidence: [roles.binding.renderCacheKey: roles],
        reportingEvidence: [roles.binding.renderCacheKey: evidence])
    #expect(active.diagnosticIdentity.hasPrefix(old.diagnosticIdentity + ":" + CTReportingPoolEvidence.revision))
    #expect(!old.diagnosticIdentity.contains(CTReportingPoolEvidence.revision))
}
