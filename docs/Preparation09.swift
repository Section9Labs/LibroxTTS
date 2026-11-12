import Foundation
import CryptoKit
import PronunciationEnglish
import KokoroAudio

func measured(_ body: () throws -> Void) rethrows -> Double {
    let start = ProcessInfo.processInfo.systemUptime
    try body()
    return ProcessInfo.processInfo.systemUptime - start
}
var rows: [[String: Any]] = []
for british in [false, true] {
    var owners: [Lexicon] = []
    let cold = try measured { owners.append(try Lexicon(british: british)) }
    let shared = try measured { for _ in 0..<4 { owners.append(try Lexicon(british: british)) } }
    rows.append(["kind": "lexicon", "british": british, "coldSeconds": cold, "fourOwnersSeconds": shared])
    withExtendedLifetime(owners) {}
}
let signal = (0..<24000).map { Float(sin(Double($0) * 0.081) * 0.2 + sin(Double($0) * 0.37) * 0.05) }
func process(_ filter: VoiceEnhancer) throws -> Data {
    var input = [Float](repeating: 0, count: 256), output = input, result: [Float] = []
    for block in 0..<((signal.count + 255) / 256 + 3) {
        for i in input.indices { let n = block * 256 + i; input[i] = n < signal.count ? signal[n] : 0 }
        try filter.process(input, into: &output)
        let first = max(0, 768 - block * 256), end = min(256, 768 + signal.count - block * 256)
        if first < end { result += output[first..<end] }
    }
    return result.withUnsafeBytes { Data($0) }
}
let filter = try VoiceEnhancer(preset: .balanced)
let reference = try process(filter)
for reused in [false, true, true, false] {
    let elapsed = try measured {
        for _ in 0..<30 {
            let next = try reused ? filter : VoiceEnhancer(preset: .balanced)
            next.reset()
            let actual = try process(next)
            precondition(actual == reference)
        }
    }
    rows.append(["kind": "dsp", "reused": reused, "seconds": elapsed,
        "pcmSHA256": SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()])
}
print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
