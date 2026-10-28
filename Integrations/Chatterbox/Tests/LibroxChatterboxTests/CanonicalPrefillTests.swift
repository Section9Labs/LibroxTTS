import Foundation
import Testing
@testable import ChatterboxCoreML

@Test func canonicalV3RetainsUnconditionalPositionsAndTwoBOSRows() {
    let p = CanonicalMTLPrefillPacker.pack(conditioning: [10, 20], lexicalText: [1, 2, 3, 4],
        textPositions: [0.25, 0.5, 0.75, 1], bos: [8, 9], window: 6, hidden: 2, useCFG: true)
    #expect(p.inputsEmbeds == [10, 20, 1.25, 2.5, 3.75, 5, 8, 9, 8, 9, 0, 0,
                              10, 20, 0.25, 0.5, 0.75, 1, 8, 9, 8, 9, 0, 0])
    #expect(p.realLength == 5)
    #expect(p.positionIds == [0, 1, 2, 3, 4, 0])
    #expect(p.logitsSelectMask == [0, 0, 0, 0, 1, 0])
}

@Test func canonicalV3ZeroGuidanceRetainsBothLexicalLanes() {
    let p = CanonicalMTLPrefillPacker.pack(conditioning: [1], lexicalText: [2], textPositions: [3],
        bos: [4], window: 4, hidden: 1, useCFG: false)
    #expect(p.inputsEmbeds == [1, 5, 4, 4, 1, 5, 4, 4])
    #expect(p.logitsSelectMask == [0, 0, 0, 1])
}

@Test func canonicalV3ZeroingOccursBeforePositionArithmetic() {
    let minusZero = Float(bitPattern: 0x80000000)
    let p = CanonicalMTLPrefillPacker.pack(conditioning: [], lexicalText: [minusZero],
        textPositions: [minusZero], bos: [1], window: 3, hidden: 1, useCFG: true)
    #expect(p.inputsEmbeds[0].bitPattern == minusZero.bitPattern)
    #expect(p.inputsEmbeds[3].bitPattern == Float.zero.bitPattern)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHATTERBOX_CANONICAL_FIXTURE_DIR"] != nil))
func canonicalV3MatchesPinnedPythonMLXRowsWithSharedConditioning() throws {
    let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CHATTERBOX_CANONICAL_FIXTURE_DIR"]))
    let tables = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CHATTERBOX_TEST_MODEL_DIR"]))
    let textEmb = try EmbeddingTable(contentsOf: tables.appendingPathComponent("text_emb.npy"), name: "text")
    let textPos = try EmbeddingTable(contentsOf: tables.appendingPathComponent("text_pos_emb.npy"), name: "position")
    let speech = try EmbeddingTable(contentsOf: tables.appendingPathComponent("speech_emb.npy"), name: "speech")
    let speechPos = try EmbeddingTable(contentsOf: tables.appendingPathComponent("speech_pos_emb.npy"), name: "speechPosition")
    let bos = zip(speech.row(6561), speechPos.row(0)).map(+)
    for language in ["en", "es"] {
        let ids = try JSONDecoder().decode([Int].self, from: Data(contentsOf: fixture.appendingPathComponent(language + "-ids.json")))
        let cond = try NPYFloat32.read(url: fixture.appendingPathComponent(language + "-conditioning.npy"))
        let expected = try NPYFloat32.read(url: fixture.appendingPathComponent(language + "-canonical.npy"))
        let lexical = ids.flatMap { Array(textEmb.row($0)) }
        let positions = ids.indices.flatMap { Array(textPos.row($0)) }
        let packed = CanonicalMTLPrefillPacker.pack(conditioning: cond.data, lexicalText: lexical,
            textPositions: positions, bos: bos, window: expected.shape[1], hidden: 1024, useCFG: true)
        #expect(packed.realLength == 36 + ids.count)
        #expect(packed.inputsEmbeds.map(\.bitPattern) == expected.data.map(\.bitPattern))
    }
}
