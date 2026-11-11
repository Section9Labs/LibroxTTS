import CryptoKit
import Foundation
import KokoroNarration

// Independent control: no preceding long-sentence workload, ten warmups and
// fifty observations per case. Every input fits without prefix-index creation.
struct Row: Codable {
    let model: String
    let inputScalars: Int
    let units: Int
    let medianSeconds: Double
    let planSHA256: String
}
var rows: [Row] = []
for (model, sizes) in [(NarrationModel.plus, [128, 256]), (.pocket, [512, 2048])] {
    for size in sizes {
        let text = String(String(repeating: "La puerta estaba abierta y nadie regresaba, ", count: 60).prefix(size))
        let voice = model == .plus ? "plus-f1-es-v1" : "pocket-caro_davy-es-v1"
        var timings: [Double] = [], signature = "", count = 0
        for iteration in 0..<60 {
            let start = ProcessInfo.processInfo.systemUptime
            let plan = try TextNativeNarrationPlanner.plan(text, voiceID: voice, model: model)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            if iteration >= 10 { timings.append(seconds) }
            count = plan.count
            signature = plan.map { "\($0.range.location):\($0.range.length):\($0.voiceID):\($0.synthesisText)" }.joined(separator: "\n")
        }
        rows.append(.init(model: model.rawValue, inputScalars: size, units: count,
            medianSeconds: timings.sorted()[timings.count / 2],
            planSHA256: SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()))
    }
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(rows), as: UTF8.self))
