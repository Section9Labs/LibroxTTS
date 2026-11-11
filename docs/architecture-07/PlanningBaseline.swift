import Foundation
import CryptoKit
import KokoroNarration
import KokoroPronunciation

// Source-only review probe. Link against the unmodified package's built objects.
// No model weights, audio, or network calls. Times describe only this machine/build.
struct Result: Codable {
    let model: String
    let inputScalars: Int
    let units: Int
    let medianSeconds: Double
    let planSHA256: String
}
var results: [Result] = []
let requestedSizes = CommandLine.arguments.dropFirst().compactMap(Int.init)
let sizes = requestedSizes.isEmpty ? [512, 2048, 8192, 16000] : requestedSizes
for model in [NarrationModel.plus, .pocket] {
    for count in sizes {
        let text = String(String(repeating: "La puerta estaba abierta y nadie regresaba, ", count: 400).prefix(count))
        let voice = model == .plus ? "plus-f1-es-v1" : "pocket-caro_davy-es-v1"
        var timings: [Double] = []
        var signature = ""
        var unitCount = 0
        for _ in 0..<3 {
            let start = ProcessInfo.processInfo.systemUptime
            let units = try TextNativeNarrationPlanner.plan(text, voiceID: voice, model: model)
            timings.append(ProcessInfo.processInfo.systemUptime - start)
            unitCount = units.count
            signature = units.map { "\($0.range.location):\($0.range.length):\($0.voiceID):\($0.synthesisText)" }.joined(separator: "\n")
        }
        let hash = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        results.append(.init(model: model.rawValue, inputScalars: text.unicodeScalars.count,
                             units: unitCount, medianSeconds: timings.sorted()[1], planSHA256: hash))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(results), as: UTF8.self))
