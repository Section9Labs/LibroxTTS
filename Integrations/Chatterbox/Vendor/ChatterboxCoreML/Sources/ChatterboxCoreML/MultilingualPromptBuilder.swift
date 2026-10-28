import Foundation

/// Canonical host frontend usable by a native decoder without loading Core ML T3.
public struct ChatterboxMultilingualPromptBuilder: Sendable {
    private let tokenizer: MTLTextTokenizer
    private let assembler: MTLPrefillAssembler
    private let speech: SpeechEmbedding
    private let positions: EmbeddingTable

    public init(modelDirectory: URL) async throws {
        tokenizer = try await MTLTextTokenizer(modelFolder: modelDirectory)
        speech = try SpeechEmbedding(contentsOf: modelDirectory.appendingPathComponent("speech_emb.npy"))
        positions = try EmbeddingTable(contentsOf: modelDirectory.appendingPathComponent("speech_pos_emb.npy"), name: "speech_pos_emb")
        assembler = MTLPrefillAssembler(
            textEmb: try EmbeddingTable(contentsOf: modelDirectory.appendingPathComponent("text_emb.npy"), name: "text_emb"),
            textPosEmb: try EmbeddingTable(contentsOf: modelDirectory.appendingPathComponent("text_pos_emb.npy"), name: "text_pos_emb"),
            speechEmb: speech, speechPosEmb: positions, condBuilder: try CondBlockBuilder(dir: modelDirectory))
    }

    public struct Prompt: Sendable {
        public let embeddings: [Float]
        public let length: Int
        public let textTokens: [Int32]
    }

    public func prepare(text: String, language: String, conditioningFile: URL,
                        exaggeration: Float, guidance: Float, maxTokens: Int = 350) throws -> Prompt {
        guard ["en", "es"].contains(language), !text.isEmpty, text.utf8.count <= 8_000,
              exaggeration.isFinite, (0...2).contains(exaggeration), guidance.isFinite,
              (0...2).contains(guidance), (2...350).contains(maxTokens)
        else { throw ChatterboxError.invalidModelOutput("Invalid native prompt options") }
        try Task.checkCancellation()
        let ids = tokenizer.encode(text, language: language)
        try MTLT3LMRunner.validateContext(textTokenCount: ids.count, prefillWindow: assembler.window,
                                        maxSequence: 1536, maxNewTokens: maxTokens)
        let conds = try Conditionals(contentsOf: conditioningFile)
        guard conds.speakerEmb.count == 256, conds.speakerEmb.allSatisfy(\.isFinite),
              !conds.condPromptSpeechTokens.isEmpty, conds.condPromptSpeechTokens.count <= 150,
              conds.condPromptSpeechTokens.allSatisfy({ $0 >= 0 && Int($0) < speech.vocab })
        else { throw ChatterboxError.invalidModelOutput("Invalid native speaker conditioning") }
        let packed = assembler.assemble(textTokens: ids, conds: conds, exaggeration: exaggeration, cfgWeight: guidance)
        let laneSize = assembler.window * 1024
        let used = packed.realLength * 1024
        let unpadded = Array(packed.inputsEmbeds[..<used]) + Array(packed.inputsEmbeds[laneSize..<(laneSize + used)])
        guard unpadded.allSatisfy(\.isFinite) else { throw ChatterboxError.invalidModelOutput("Nonfinite native prompt") }
        return Prompt(embeddings: unpadded, length: packed.realLength, textTokens: ids)
    }

    public func speechInput(token: Int, position: Int) throws -> [Float] {
        guard (0..<speech.vocab).contains(token), (1..<positions.rows).contains(position)
        else { throw ChatterboxError.invalidModelOutput("Native speech embedding overflow") }
        return zip(speech.row(token), positions.row(position)).map(+)
    }
}
