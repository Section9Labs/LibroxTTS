import Foundation
import Testing
import KokoroPronunciation
@testable import KokoroNarration

@Test func expressionIsScopedToDialogueAndDoesNotAlterSourceOrTiming() async throws {
    let text = "“Come back now,” Nora said angrily. The hallway was quiet."
    let cast = try BookVoiceCast(bookID: "expression", language: .english, narratorVoiceID: "af_heart", voicePool: [])
    let planner = BookNarrationPlanner()
    let natural = try await planner.plan(text, chapterID: "1", cast: cast, profile: .enhanced)
    let expressive = try await planner.plan(text, chapterID: "1", cast: cast, profile: .enhanced, delivery: .init(expressive: true))
    #expect(expressive.units.map(\.text) == natural.units.map(\.text))
    #expect(expressive.units.map(\.phonemes) == natural.units.map(\.phonemes))
    #expect(expressive.cast == natural.cast)
    #expect(natural.units.allSatisfy { $0.expressiveFocus.isEmpty })
    let focused = expressive.units.filter { !$0.expressiveFocus.isEmpty }
    #expect(!focused.isEmpty)
    for unit in focused {
        #expect(NarrationProfile.enhanced.speed(for: unit) == 1)
        for cue in unit.expressiveFocus {
            let phones = Array(unit.phonemes.unicodeScalars)
            let actual = String(String.UnicodeScalarView(phones[cue.phonemeRange]))
            #expect(!actual.contains("nˈɔɹə"))
            #expect(cue.reason == "explicit-angry")
        }
    }
}

@Test func spanishExpressionAndNegatedCueRemainDistinct() async throws {
    let planner = BookNarrationPlanner()
    let cast = try BookVoiceCast(bookID: "es-expression", language: .spanish, narratorVoiceID: "em_santa", voicePool: [])
    for (text, expected) in [("—Vuelve ahora —dijo Nora con rabia.", true),
                             ("—Vuelve ahora —dijo Nora sin rabia.", false),
                             ("—¡Vuelve ahora! —gritó Nora.", false)] {
        let result = try await planner.plan(text, chapterID: "1", cast: cast, profile: .enhanced, delivery: .init(expressive: true))
        #expect(result.units.map(\.text).joined() == text)
        #expect(result.units.contains { !$0.expressiveFocus.isEmpty } == expected)
    }
}

@Test func blendsAreStableAndUnlistedVoicesAbstain() {
    let options = NarrationDeliveryOptions(blendedVoice: true)
    #expect(options.secondaryVoice(for: "ef_dora")?.id == "em_santa")
    #expect(options.secondaryVoice(for: "af_heart")?.id == "af_bella")
    #expect(options.secondaryVoice(for: "em_alex") == nil)
    #expect(options.secondaryVoice(for: "zf_xiaobei") == nil)
    #expect(NarrationDeliveryOptions().secondaryVoice(for: "ef_dora") == nil)
    #expect(options.cacheIdentity != NarrationDeliveryOptions().cacheIdentity)
}
