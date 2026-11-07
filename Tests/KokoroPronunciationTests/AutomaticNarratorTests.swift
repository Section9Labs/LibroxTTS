// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import Testing
@testable import KokoroPronunciation

private func newCast(_ language: PronunciationLanguage = .spanish, voices: [String] = ["ef_dora", "em_alex"]) throws -> BookVoiceCast {
    try BookVoiceCast(bookID: "book-1", language: language, narratorVoiceID: "narrator", voicePool: voices)
}
private func analyze(_ text: String, _ cast: inout BookVoiceCast, chapter: String = "I") throws -> ChapterAttribution {
    try SpeakerAttributor().analyze(text, bookID: "book-1", chapterID: chapter, cast: &cast)
}

@Test func explicitSpanishTagsSeparateCharactersFromNarratorAsides() throws {
    var cast = try newCast()
    let text = "«Señores—dijo Amparo sonriendo—, apartarse. Voy a poner la mesa».\n\nY mientras extendía el mantel, Caballero, mirándola, contestaba maquinalmente:\n\n«Hoy no puedo. Me quedaré otro día»."
    let result = try analyze(text, &cast)
    #expect(cast.characters.map(\.name) == ["Amparo", "Caballero"])
    #expect(result.annotations.count == 3)
    #expect(result.decisions.allSatisfy { $0.reason == .explicitName })
    let spans = try StoryNarrator().plan(text, narratorVoiceID: cast.narratorVoiceID, characterVoices: cast.characterVoices,
                                       dialogue: result.annotations, mode: .characterVoices)
    #expect(spans.map(\.text).joined() == text)
    #expect(spans.first(where: { $0.text.contains("dijo Amparo") })?.voiceID == "narrator")
    #expect(spans.filter { $0.role == .dialogue }.map(\.voiceID) == ["ef_dora", "ef_dora", "em_alex"])
}

@Test func explicitEnglishTagsSupportBothWordOrdersAndContinuation() throws {
    var cast = try newCast(.english, voices: ["af_heart", "am_michael"])
    let text = "Alice said: “Hello.” “Welcome,” replied Bob. “Wait,” Alice said, “I forgot something.”"
    let r = try analyze(text, &cast)
    #expect(cast.characters.map(\.name) == ["Alice", "Bob"])
    #expect(r.annotations.map(\.speakerID) == ["c1", "c2", "c1", "c1"])
}

@Test func spanishDashDialogueWorksWithoutGuessingUnmarkedTurns() throws {
    var cast = try newCast()
    let text = "—No iré—dijo Ana, sonriendo—. Será mañana.\n—Entonces esperaré.\n—De acuerdo—respondió Pedro."
    let result = try analyze(text, &cast)
    #expect(result.decisions.map(\.reason) == [.explicitName, .unresolved, .explicitName])
    #expect(result.annotations.map(\.speakerID) == ["c1", "c1", "c2"])
    #expect(cast.characters.map(\.name) == ["Ana", "Pedro"])
}

@Test func pronounsThoughtsAndConflictingTagsDoNotInventSpeakers() throws {
    var cast = try newCast()
    for text in ["Ella dijo: «No».", "Él contestó: «Sí».", "Yo dije: «Hola».",
                 "Pensó Ana: «No».", "«No», dijo alguien.", "«No», dijo Ana y Pedro.",
                 "Ana dijo: «No», dijo Pedro.", "«Le dije “hola”», dijo Ana."] {
        let before = cast
        let r = try analyze(text, &cast)
        #expect(r.annotations.isEmpty, "\(text)")
        #expect(cast == before, "\(text)")
    }
}

@Test func bookIdentityAndVoicesSurviveColdRestoreAndChapterOrderChanges() throws {
    var cast = try newCast()
    _ = try analyze("«Hola», dijo Ana. «Adiós», dijo Pedro.", &cast)
    let snapshot = try cast.encoded()
    cast = try BookVoiceCast.restore(snapshot, bookID: "book-1")
    let later = try analyze("«Aquí estoy», dijo Pedro. «Te veo», dijo Ana.", &cast, chapter: "XX")
    #expect(later.annotations.map(\.speakerID) == ["c2", "c1"])
    #expect(cast.characterVoices == ["c1":"ef_dora", "c2":"em_alex"])
    #expect(try cast.encoded() == snapshot) // Analysis does not accumulate chapter history.
    #expect(throws: BookVoiceCast.CastError.wrongBook) { try BookVoiceCast.restore(snapshot, bookID: "another-book") }
    #expect(throws: BookVoiceCast.CastError.wrongBook) {
        try SpeakerAttributor().analyze("Ana dijo: «No».", bookID: "another", chapterID: "I", cast: &cast)
    }
}

@Test func confirmedAliasesAndVoiceCorrectionsPersistWithoutFuzzyMerges() throws {
    var cast = try newCast()
    _ = try analyze("«Hola», dijo Don Agustín Caballero.", &cast)
    #expect(cast.characters.first?.name == "Agustín Caballero")
    try cast.addAlias("Caballero", to: "c1")
    try cast.setVoice("em_alex", for: "c1")
    cast = try BookVoiceCast.restore(cast.encoded(), bookID: "book-1")
    let r = try analyze("«Otra vez», dijo Caballero.", &cast, chapter: "XL")
    #expect(r.annotations.first?.speakerID == "c1")
    #expect(cast.characterVoices["c1"] == "em_alex")
    _ = try analyze("«Bien», dijo Amparo.", &cast)
    #expect(throws: BookVoiceCast.CastError.aliasConflict) { try cast.addAlias("Caballero", to: "c2") }
}

@Test func exhaustedVoicePoolFallsBackInsteadOfReassigningExistingVoices() throws {
    var cast = try newCast(voices: ["ef_dora"])
    let r = try analyze("«Uno», dijo Ana. «Dos», dijo Pedro.", &cast)
    #expect(cast.characters.count == 2)
    #expect(r.decisions.map(\.reason) == [.explicitName, .noCharacterVoice])
    #expect(r.annotations.count == 1)
    #expect(cast.characterVoices == ["c1":"ef_dora"])
}

@Test func automaticAttributionBoundsAndRestoreValidationAreEnforced() throws {
    var cast = try newCast()
    let before = cast
    #expect(throws: PronunciationError.self) { try analyze(String(repeating: "a", count: 16_385), &cast) }
    #expect(cast == before)
    #expect(throws: BookVoiceCast.CastError.limitExceeded) {
        try BookVoiceCast.restore(Data(repeating: 32, count: 131_073), bookID: "book-1")
    }
    let data = try cast.encoded()
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 99
    #expect(throws: BookVoiceCast.CastError.invalidState) {
        try BookVoiceCast.restore(JSONSerialization.data(withJSONObject: object), bookID: "book-1")
    }
    var other = try BookVoiceCast(bookID: "book-1", languageCode: "xx", narratorVoiceID: "narrator", voicePool: [])
    #expect(throws: SpeakerAttributor.AttributionError.unsupportedLanguage) { try analyze("こんにちは", &other) }
}

@Test func explicitContextSelectsCompatibleVoicesWithoutNameStereotypes() throws {
    var cast = try BookVoiceCast(bookID: "book-1", language: .spanish, narratorVoiceID: "em_santa",
        voicePool: ["em_alex", "ef_dora"], voiceGenders: ["em_santa": .male, "em_alex": .male, "ef_dora": .female],
        voiceSharing: .reuseCompatible)
    _ = try analyze("Su hermana Alex llegó. «Hola», dijo Alex. «Sí», dijo Don María.", &cast)
    #expect(cast.characters.map(\.gender) == [.female, .male])
    #expect(cast.characters.map(\.voiceID) == ["ef_dora", "em_alex"])
    #expect(cast.characters[0].genderEvidence[0].quote == "Su hermana Alex")
    _ = try analyze("«Bien», dijo Doña Elena. «Voy», dijo Don Pablo.", &cast, chapter: "II")
    #expect(cast.characters.map(\.voiceID) == ["ef_dora", "em_alex", "ef_dora", "em_alex"])
    #expect(try BookVoiceCast.restore(cast.encoded(), bookID: "book-1") == cast)
}

@Test func femaleNarratorCanBeSharedWhenNoOtherFemaleVoiceExists() throws {
    var cast = try BookVoiceCast(bookID: "book-1", language: .spanish, narratorVoiceID: "ef_dora",
        voicePool: ["em_alex", "em_santa"], voiceGenders: ["em_santa": .male, "em_alex": .male, "ef_dora": .female],
        voiceSharing: .reuseCompatible)
    _ = try analyze("«Hola», dijo Doña Ana. «Sí», dijo Don Pedro.", &cast)
    #expect(cast.characters.map(\.voiceID) == ["ef_dora", "em_alex"])
}

@Test func LaterContextFlagsReviewWithoutChangingHeardVoiceAndConflictsStayExplicit() throws {
    var cast = try BookVoiceCast(bookID: "book-1", language: .english, narratorVoiceID: "narrator",
        voicePool: ["am_michael", "af_heart"], voiceGenders: ["am_michael": .male, "af_heart": .female])
    _ = try analyze("Alice said: “Hello.”", &cast)
    #expect(cast.characters[0].gender == .unknown) // A name alone supplies no evidence.
    #expect(cast.characters[0].voiceID == "am_michael")
    _ = try analyze("Alice, his sister, arrived. “Hello,” said Alice.", &cast, chapter: "II")
    #expect(cast.characters[0].gender == .female)
    #expect(cast.characters[0].voiceID == "am_michael")
    #expect(cast.voiceReviewIDs == ["c1"])
    try cast.setVoice("af_heart", for: "c1")
    #expect(cast.voiceReviewIDs.isEmpty)
    _ = try analyze("Their brother Alice arrived. “Yes,” said Alice.", &cast, chapter: "III")
    #expect(cast.characters[0].gender == .conflicting)
    #expect(cast.characters[0].genderEvidence.count == 2)
    #expect(cast.characters[0].voiceID == "af_heart")
    let snapshot = try cast.encoded()
    for _ in 0..<10 { _ = try analyze("Mrs. Alice said: “Hello.”", &cast) }
    #expect(try cast.encoded() == snapshot)
}

@Test func boundedBookCastKeepsEarlierVoicesWhenNewCharactersExceedLimit() throws {
    var cast = try newCast()
    func name(_ i: Int) -> String {
        "Persona" + String(UnicodeScalar(65 + i / 26)!) + String(UnicodeScalar(65 + i % 26)!)
    }
    let text = (0..<65).map { "«Sí», dijo \(name($0))." }.joined(separator: " ")
    let result = try analyze(text, &cast)
    #expect(cast.characters.count == 64)
    #expect(result.decisions.last?.reason == .castLimit)
    #expect(cast.characterVoices == ["c1": "ef_dora", "c2": "em_alex"])
    #expect(try BookVoiceCast.restore(cast.encoded(), bookID: "book-1") == cast)
    let before = cast
    let oversizedCandidates = String(repeating: "«Sí», dijo Ana. ", count: 257)
    #expect(throws: StoryNarrator.PlanningError.tooManyAnnotations) { try analyze(oversizedCandidates, &cast) }
    #expect(cast == before)
}

@Test func charactersInDifferentBooksHaveIndependentCorrections() throws {
    var first = try newCast()
    _ = try analyze("«Hola», dijo Ana.", &first)
    try first.setVoice("em_alex", for: "c1")
    var second = try BookVoiceCast(bookID: "book-2", language: .spanish, narratorVoiceID: "narrator", voicePool: ["ef_dora", "em_alex"])
    _ = try SpeakerAttributor().analyze("«Hola», dijo Ana.", bookID: "book-2", chapterID: "I", cast: &second)
    #expect(first.characters[0].voiceID == "em_alex")
    #expect(second.characters[0].voiceID == "ef_dora")
}

@Test func narratorCorrectionPreservesBookIdentities() throws {
    var cast = try BookVoiceCast(bookID: "correction", language: .spanish, narratorVoiceID: "em_santa",
        voicePool: ["ef_dora", "em_alex"], voiceGenders: ["em_santa": .male, "ef_dora": .female, "em_alex": .male],
        voiceSharing: .reuseCompatible)
    _ = try SpeakerAttributor().analyze("—Volveré mañana —dijo Elena.", bookID: "correction", chapterID: "1", cast: &cast)
    let corrected = try cast.replacingNarrator(with: "em_alex")
    #expect(corrected.narratorVoiceID == "em_alex")
    #expect(corrected.characters == cast.characters)
    #expect(corrected.aliases == cast.aliases)
    #expect(corrected.characterVoices == cast.characterVoices)
    #expect(!corrected.voicePool.contains("em_alex"))
    #expect(corrected.voicePool.contains("em_santa"))
    #expect(try BookVoiceCast.restore(corrected.encoded(), bookID: "correction") == corrected)
}
