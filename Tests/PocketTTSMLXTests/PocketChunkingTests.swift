import Foundation
import Testing
import KokoroCatalog
import LibroxTTS
@testable import PocketTTSMLX

// Word-count fixtures isolate boundary decisions; installed-asset tests below
// also exercise the actual language tokenizer and prompt preparation.
private func chunks(_ text: String, role: PocketTTSPassageRole = .narration,
                    options: PocketTTSChunkingOptions = .init()) throws -> [PocketTTSTextChunk] {
    try PocketTTSPassageChunker.plan(text, language: "en", role: role, options: options,
        prepare: { $0 }, tokenCount: { $0.split(whereSeparator: \.isWhitespace).count })
}

@Test func pocketChunksKeepWholeSentencesAndShortConnectedThoughts() throws {
    let options = PocketTTSChunkingOptions(narrationTargetTokens: 8, dialogueTargetTokens: 8,
                                         maximumTokens: 24, shortSentenceTokens: 3)
    let long = "She watched the light fall slowly across the empty room and remembered the garden."
    #expect(try chunks(long, options: options).map(\.text) == [long])
    for text in [long + " Nobody came.", "She waited. " + long,
                 "The garden was quiet this morning. But beyond the wall the children were already beginning their games."] {
        #expect(try chunks(text, options: options).map(\.text) == [text])
    }
}

@Test func pocketChunkTargetsDependOnRoleButNeverPadShortTurns() throws {
    let sentence = "The light fell gently across the room."
    let text = Array(repeating: sentence, count: 4).joined(separator: " ")
    let options = PocketTTSChunkingOptions(narrationTargetTokens: 20, dialogueTargetTokens: 10,
                                         maximumTokens: 24, shortSentenceTokens: 0)
    #expect(try chunks(text, options: options).count == 2)
    #expect(try chunks(text, role: .dialogue, options: options).count == 4)
    #expect(try chunks("No.", role: .dialogue, options: options).map(\.text) == ["No."])
}

@Test func pocketProtectedPassageStaysTogetherOrFailsExplicitly() throws {
    let text = "The light fell across the room. Outside, someone was singing softly."
    let options = PocketTTSChunkingOptions(narrationTargetTokens: 8, dialogueTargetTokens: 8,
                                         maximumTokens: 24, grouping: .keepTogether)
    #expect(try chunks(text, options: options).map(\.text) == [text])
    #expect(try chunks(text + "\n\n" + text, options: options).count == 2)
    #expect(throws: PocketTTSError.self) {
        try chunks(Array(repeating: text, count: 4).joined(separator: " "), options: options)
    }
}

@Test func pocketChunkParagraphsResetAndPreserveUnicodeAndDecimalContent() throws {
    let text = "Dr. Vale paid 3.14 euros at the café. She kept the receipt.\n\n“Wait!” The lamp 🪔 went out."
    let plan = try chunks(text)
    #expect(plan.count == 2)
    #expect(plan.allSatisfy { $0.startsNewPassage && $0.boundaryAfter == .paragraph })
    #expect(plan.map(\.text).joined(separator: " ") == text.replacingOccurrences(of: "\n\n", with: " "))
}

@Test func pocketChunkHardCapUsesClausesThenWholeWordsWithoutDroppingText() throws {
    let text = "We waited beside the gate, while rain fell slowly across the street and the last bus disappeared into the dark."
    let options = PocketTTSChunkingOptions(narrationTargetTokens: 8, dialogueTargetTokens: 8,
                                         maximumTokens: 10, shortSentenceTokens: 0)
    let plan = try chunks(text, options: options)
    #expect(plan.first?.text == "We waited beside the gate,")
    #expect(plan.first?.boundaryAfter == .clause)
    #expect(plan.contains { $0.boundaryAfter == .word })
    #expect(plan.allSatisfy { $0.tokenCount <= 10 })
    #expect(plan.map(\.text).joined(separator: " ") == text)
    #expect(plan.filter(\.startsNewPassage).count == 1)
    #expect(throws: PocketTTSError.self) {
        try PocketTTSPassageChunker.plan("unbreakable", language: "en", role: .narration, options: options,
            prepare: { $0 }, tokenCount: { $0.count })
    }
}

@Test func pocketChunkOptionsAreValidatedAndEnterRenderIdentity() async throws {
    let pipeline = NarrationPipeline()
    let options = PocketTTSChunkingOptions(narrationTargetTokens: 60, dialogueTargetTokens: 24)
    let plan = try await pipeline.plan("She waited. Nobody came.", model: .pocket, bookID: "book", chapterID: "one",
        narratorVoiceID: "pocket-alba-en-v1", language: "en", pocketChunking: options)
    var unit = try #require(plan.units.first)
    #expect(unit.pocketChunking == options)
    let original = NarrationModel.pocket.renderIdentity(for: unit)
    unit.pocketChunking?.narrationTargetTokens = 40
    #expect(NarrationModel.pocket.renderIdentity(for: unit) != original)
    unit.pocketChunking = options
    unit.role = .dialogue
    #expect(NarrationModel.pocket.renderIdentity(for: unit) != original)
    let encoded = try JSONEncoder().encode(options)
    #expect(try JSONDecoder().decode(PocketTTSChunkingOptions.self, from: encoded) == options)
    await #expect(throws: PocketTTSChunkingOptions.ValidationError.self) {
        try await pipeline.plan("Hello.", model: .pocket, bookID: "book", chapterID: "one",
            narratorVoiceID: "pocket-alba-en-v1", language: "en",
            pocketChunking: .init(maximumTokens: 1000))
    }
    let longSource = String(repeating: "She waited beside the café 🪔. ", count: 12)
    let bounded = try await pipeline.plan(longSource, model: .pocket, bookID: "book", chapterID: "two",
        narratorVoiceID: "pocket-alba-en-v1", language: "en",
        pocketChunking: .init(maximumUnitScalars: 128))
    #expect(bounded.units.count > 1)
    for part in bounded.units {
        #expect(part.text == (longSource as NSString).substring(with: part.range))
        #expect(Range(part.range, in: longSource) != nil)
        #expect(part.synthesisText.unicodeScalars.count <= 128)
    }
    await #expect(throws: (any Error).self) {
        try await pipeline.plan(longSource, model: .pocket, bookID: "book", chapterID: "two",
            narratorVoiceID: "pocket-alba-en-v1", language: "en",
            pocketChunking: .init(maximumUnitScalars: 128, grouping: .keepTogether))
    }
}

@Test func pocketSpeakerTurnsStaySeparateEvenWhenVoicesAreShared() async throws {
    let pipeline = NarrationPipeline()
    let text = "Clara was her sister. James was her brother.\n“Please stay. I need you here,” said Clara.\n“No,” said James."
    let first = try await pipeline.plan(text, model: .pocket, bookID: "book", chapterID: "one",
        narratorVoiceID: "pocket-alba-en-v1", language: "en", characterVoices: true)
    var cast = try #require(first.cast)
    #expect(cast.characters.count == 2)
    for character in cast.characters { try cast.setVoice("pocket-alba-en-v1", for: character.id) }
    let options = PocketTTSChunkingOptions(narrationTargetTokens: 80, dialogueTargetTokens: 80)
    let plan = try await pipeline.plan(text, model: .pocket, bookID: "book", chapterID: "two",
        narratorVoiceID: "pocket-alba-en-v1", language: "en", cast: cast, characterVoices: true,
        pocketChunking: options)
    let dialogue = plan.units.filter { $0.role == .dialogue }
    #expect(dialogue.count == 2)
    #expect(dialogue.map(\.speakerID) == ["c1", "c2"])
    #expect(dialogue.first?.text.contains("Please stay. I need you here") == true)
    #expect(dialogue.allSatisfy { $0.voiceID == "pocket-alba-en-v1" })
    for unit in plan.units {
        #expect(unit.text == (text as NSString).substring(with: unit.range))
        #expect(unit.pocketChunking == options)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
func pocketChunksUseRealTokenizerAndExposeDecisions() async throws {
    let root = ProcessInfo.processInfo.environment["POCKET_ASSETS"]!
    let engine = PocketTTSEngine(directory: URL(fileURLWithPath: root))
    let text = "She rested her hand against the door. For a moment, she could almost hear his voice again.\n\nThen the telephone rang."
    let options = PocketTTSChunkingOptions(narrationTargetTokens: 40, dialogueTargetTokens: 24, maximumTokens: 64)
    let plan = try await engine.previewChunks(text, voiceID: "pocket-alba-en-v1", chunking: options)
    #expect(plan.filter(\.startsNewPassage).count == 2)
    #expect(plan.allSatisfy { $0.tokenCount <= 64 })
    #expect(plan.map(\.text).joined(separator: " ") == text.replacingOccurrences(of: "\n\n", with: " "))
    await engine.unload()
}
