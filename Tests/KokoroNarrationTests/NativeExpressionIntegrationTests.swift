import Foundation
import Testing
import LibroxCTNative
@testable import KokoroNarration

private let source = "Mara checked the drawer. \"It is with me,\" Mara said softly while she held the door. The window broke. \"Stay here,\" Mara said."

@Test func approvedExpressionIsOptInAndBounded() async throws {
    let pipeline = NarrationPipeline()
    let baseline = try await pipeline.plan(source, model: .plus, bookID: "test", chapterID: "1",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true)
    let prepared = try await pipeline.plan(source, model: .plus, bookID: "test", chapterID: "1",
        narratorVoiceID: "plus-f1-en-v1", language: "en", cast: baseline.cast,
        characterVoices: true, nativeExpression: true)
    #expect(baseline.units.allSatisfy { $0.nativeExpression == nil && $0.nativeTextContext == nil })
    #expect(prepared.units.map(\.text) == baseline.units.map(\.text))
    #expect(prepared.units.map(\.range) == baseline.units.map(\.range))
    #expect(prepared.units.map(\.voiceID) == baseline.units.map(\.voiceID))
    #expect(prepared.units.contains { $0.nativeExpression != nil })
    for (old, unit) in zip(baseline.units, prepared.units) {
        if let input = unit.nativeExpression {
            #expect(unit.role == .dialogue)
            #expect(input.roles.spans.count <= 5)
            #expect(input.binding == unit.nativeTextContext)
            #expect(input.binding.spokenText == unit.synthesisText)
            #expect(!input.binding.contextText.contains("\n"))
            #expect(NarrationModel.plus.renderIdentity(for: old) != NarrationModel.plus.renderIdentity(for: unit))
        } else { #expect(unit.role != .dialogue) }
    }
    let blended = try await pipeline.plan(source, model: .plus, bookID: "test", chapterID: "1",
        narratorVoiceID: "plus-f1-en-v1", language: "en", cast: baseline.cast,
        characterVoices: true, delivery: .init(blendedVoice: true), nativeExpression: true)
    #expect(blended.units.allSatisfy { $0.nativeExpression == nil })
}

@Test func approvedExpressionIdentityIncludesReportingAndRoleEvidence() async throws {
    let plan = try await NarrationPipeline().plan(source, model: .plus, bookID: "test", chapterID: "1",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true, nativeExpression: true)
    let input = try #require(plan.units.compactMap(\.nativeExpression).first)
    let fallback = try CTExpressionInput(roles: input.roles,
        reporting: .init(binding: input.binding, disposition: "forced-fallback"))
    #expect(input.cacheIdentity != fallback.cacheIdentity)
    #expect(input.cacheIdentity.contains(CTApprovedExpression.manifestSHA256))
    #expect(input.cacheIdentity.contains(input.roles.identity))
    #expect(input.cacheIdentity.contains(input.reporting.identity))
}

@Test func approvedExpressionLeavesNarrationAndAllLanguageAvailabilityIntact() async throws {
    for language in NarrationModel.plus.supportedLanguageCodes {
        let voice = "plus-f1-\(language)-v1"
        let unit = BookNarrationUnit(sourceText: "123.", sourceRange: NSRange(location: 0, length: 4),
            narratorID: voice, role: .narration)
        let result = try NarrationNativeExpression.prepare(units: [unit], source: "123.", decisions: [])
        #expect(result[0].voiceID == voice)
        #expect(result[0].nativeExpression == nil)
        #expect(result[0].nativeTextContext == nil)
    }
}
