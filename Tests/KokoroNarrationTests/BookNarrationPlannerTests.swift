// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import Testing
import KokoroCatalog
import KokoroPronunciation
@testable import KokoroNarration

@Test func sourceRangesSurviveCharacterPlanning() async throws {
    let text = "  La casa estaba en silencio.\n\n—La lluvia ha cesado —dijo Clara.\nClara dejó la carta junto a la lámpara.  "
    let cast = try BookVoiceCast(bookID: "book", language: .spanish, narratorVoiceID: "em_santa",
                                 voicePool: ["ef_dora", "em_alex"], voiceSharing: .reuseCompatible)
    let plan = try await BookNarrationPlanner().plan(text, chapterID: "one", cast: cast, characterVoices: true)
    #expect(plan.units.map(\.text).joined() == text)
    for unit in plan.units {
        #expect((text as NSString).substring(with: unit.range) == unit.text)
        #expect(!unit.phonemes.isEmpty)
    }
    #expect(plan.cast.characters.contains { $0.name == "Clara" })
    let restored = try BookVoiceCast.restore(plan.cast.encoded(), bookID: "book")
    let next = try await BookNarrationPlanner().plan("—Volveré mañana —dijo Clara.", chapterID: "two", cast: restored, characterVoices: true)
    #expect(next.cast.characterVoices == plan.cast.characterVoices)
    #expect(next.cast.narratorVoiceID == "em_santa")
}

@Test func singleNarratorDoesNotRecastBook() async throws {
    let cast = try BookVoiceCast(bookID: "book", language: .english, narratorVoiceID: "af_heart", voicePool: ["am_santa"])
    let text = "“Come in,” said Alice. She waited quietly."
    let result = try await BookNarrationPlanner().plan(text, chapterID: "1", cast: cast)
    #expect(result.units.allSatisfy { $0.voiceID == "af_heart" })
    #expect(result.cast == cast)
    #expect(result.attribution == nil)
}

@Test func supportedAttributionDoesNotInventSpeakersWithoutEvidence() async throws {
    let cast = try BookVoiceCast(bookID: "book", language: .italian, narratorVoiceID: "if_sara", voicePool: ["im_nicola"])
    let result = try await BookNarrationPlanner().plan("La luce della sera entrava nella stanza.", chapterID: "1", cast: cast, characterVoices: true)
    #expect(result.characterAttributionSupported)
    #expect(result.cast == cast)
    #expect(result.units.allSatisfy { $0.voiceID == "if_sara" })
}

@Test func rejectsCrossLanguageCastAndUnboundedInput() async throws {
    let wrong = try BookVoiceCast(bookID: "book", language: .spanish, narratorVoiceID: "af_heart", voicePool: [])
    await #expect(throws: BookNarrationPlanner.PlanningError.languageMismatch) {
        try await BookNarrationPlanner().plan("Hola.", chapterID: "1", cast: wrong)
    }
    let cast = try BookVoiceCast(bookID: "book", language: .spanish, narratorVoiceID: "ef_dora", voicePool: [])
    await #expect(throws: PronunciationError.self) {
        try await BookNarrationPlanner().plan(String(repeating: "a", count: 16_385), chapterID: "1", cast: cast)
    }
}
