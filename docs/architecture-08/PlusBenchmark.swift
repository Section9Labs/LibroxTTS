import Foundation
import CryptoKit
import LibroxCTNative

@main struct PlusBenchmark {
    static func main() async throws {
        let args = CommandLine.arguments
        let assets = URL(fileURLWithPath: args[1]), baseline = URL(fileURLWithPath: args[2])
        let engine = CTEngine(directory: assets, backend: .coreMLCPU)
        try await engine.load()
        var rows: [[String: Any]] = []
        for (language, text) in [("en", "The door was open."), ("es", "La puerta estaba abierta.")] {
            let noise = try CTTensor(shape: JSONDecoder().decode([Int].self, from: Data(contentsOf:
                baseline.appendingPathComponent("plus-\(language)-noise-shape.json"))), kind: .float32,
                data: Data(contentsOf: baseline.appendingPathComponent("plus-\(language)-noise.f32")))
            let reference = try Data(contentsOf: baseline.appendingPathComponent("plus-\(language)-0.f32"))
            for trial in -2..<4 {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try await engine.synthesize(text, language: language, initialNoise: noise)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let pcm = result.samples.withUnsafeBytes { Data($0) }
                guard pcm == reference else { fatalError("PCM changed: \(language)") }
                if trial >= 0 {
                    rows.append(["language": language, "trial": trial, "seconds": elapsed,
                        "graphs": result.graphSeconds, "samples": result.samples.count,
                        "sha256": SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined()])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: args[3]))
    }
}
