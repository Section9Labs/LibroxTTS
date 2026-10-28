import Foundation

/// Checks the bounded multilingual V3 conditioning format, not speaker identity.
public enum ChatterboxVoiceFile {
    public static let maximumBytes = 1_048_576
    public static func validate(at url: URL) throws {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= maximumBytes else { throw invalid() }
        let data = try Data(contentsOf: url)
        guard (8...maximumBytes).contains(data.count) else { throw invalid() }
        let headerBytes = data.prefix(8).enumerated().reduce(UInt64.zero) { $0 | UInt64($1.element) << ($1.offset * 8) }
        guard headerBytes <= 65_536, headerBytes <= UInt64(data.count - 8),
              let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + Int(headerBytes)))) as? [String: Any]
        else { throw invalid() }
        let expected: [String: ([ClosedRange<Int>], String)] = [
            "t3.speaker_emb": ([256...256], "F32"),
            "t3.cond_prompt_speech_tokens": ([1...150], "I32"),
            "gen.embedding": ([192...192], "F32"),
            "gen.prompt_token": ([1...250], "I32"),
            "gen.prompt_token_len": ([1...1], "I32"),
            "gen.prompt_feat": ([1...500, 80...80], "F32")]
        guard Set(header.keys).subtracting(["__metadata__"]) == Set(expected.keys) else { throw invalid() }
        let payload = data.count - 8 - Int(headerBytes)
        var ranges: [Range<Int>] = []
        for (key, specification) in expected {
            guard let item = header[key] as? [String: Any], let shape = item["shape"] as? [Int],
                  shape.count == specification.0.count, zip(shape, specification.0).allSatisfy({ $1.contains($0) }),
                  item["dtype"] as? String == specification.1,
                  let offsets = item["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= payload,
                  offsets[1] - offsets[0] == shape.reduce(1, *) * 4
            else { throw invalid() }
            ranges.append(offsets[0]..<offsets[1])
        }
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        guard ordered.first?.lowerBound == 0, ordered.last?.upperBound == payload,
              zip(ordered, ordered.dropFirst()).allSatisfy({ $0.upperBound == $1.lowerBound }),
              let lengthItem = header["gen.prompt_token_len"] as? [String: Any],
              let lengthOffsets = lengthItem["data_offsets"] as? [Int],
              let tokenItem = header["gen.prompt_token"] as? [String: Any], let tokenShape = tokenItem["shape"] as? [Int]
        else { throw invalid() }
        let start = 8 + Int(headerBytes) + lengthOffsets[0]
        let length = data[start..<(start + 4)].enumerated().reduce(UInt32.zero) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length > 0, length <= tokenShape[0] else { throw invalid() }
        let value = try Conditionals(contentsOf: url)
        guard value.speakerEmb.allSatisfy(\.isFinite), value.genEmbedding.allSatisfy(\.isFinite),
              value.promptFeat.allSatisfy(\.isFinite),
              value.condPromptSpeechTokens.allSatisfy({ (0..<8194).contains($0) }),
              value.promptTokens.allSatisfy({ (0..<6561).contains($0) })
        else { throw invalid() }
    }
    private static func invalid() -> ChatterboxError { .invalidModelOutput("Invalid multilingual V3 voice profile") }
}
