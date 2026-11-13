import Foundation
import CryptoKit
import Synchronization
import XCTest
import KokoroCatalog
import PocketTTSCoreML
import PocketTTSMLX
import MLX
import LibroxCTNative

/// Opt-in baseline/candidate comparison. PCM stays local; hashes and timings
/// are review receipts. Missing assets skip ordinary package tests explicitly.
final class Release10MLXAudioTests: XCTestCase {
    struct Event: Codable, Equatable {
        let text: String
        let start: Int
        let end: Int
        let accepted: Int
    }
    struct Row: Codable {
        let name: String
        let samples: Int
        let sha256: String
        let seconds: Double
        let firstFrameSeconds: Double
        let events: [Event]
    }
    private func save(_ samples: [Float], name: String, seconds: Double, first: Double,
                      events: [Event], output: URL, baseline: URL?) throws -> Row {
        let pcm = samples.withUnsafeBytes { Data($0) }
        let filename = name + ".f32"
        if let baseline {
            XCTAssertEqual(pcm, try Data(contentsOf: baseline.appendingPathComponent(filename)), name)
            let old = try JSONDecoder().decode(Row.self, from: Data(contentsOf: baseline.appendingPathComponent(name + ".json")))
            XCTAssertEqual(events, old.events, "Chunk metadata changed: \(name)")
        }
        let row = Row(name: name, samples: samples.count,
            sha256: SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined(),
            seconds: seconds, firstFrameSeconds: first, events: events)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try pcm.write(to: output.appendingPathComponent(filename), options: .atomic)
        try encoder.encode(row).write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
        return row
    }

    func testPrivateExecutionPCMAndEventsAgainst09() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LIBROX_10_MLX_ASSETS"], let outputPath = env["LIBROX_10_AUDIO_OUTPUT"] else {
            throw XCTSkip("Requires verified local Pocket assets and an explicit evidence destination")
        }
        let root = URL(fileURLWithPath: path), output = URL(fileURLWithPath: outputPath)
        let baseline = env["LIBROX_10_AUDIO_BASELINE"].map { URL(fileURLWithPath: $0) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let metal = env["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: metal) }
        let engine = PocketTTSEngine(directory: root, backend: env["LIBROX_10_BACKEND"] == "cpu" ? .cpu : .gpu)
        await engine.setCPUBudgetFraction(nil)
        // All supported sampler counts, revisits of the shared graph, voice/style
        // switches, and multi-chunk continuation use one loaded engine per language.
        for code in ["en", "es"] {
            let short = code == "en" ? "The door was open." : "La puerta estaba abierta."
            let long = code == "en" ? "The door was open. She returned to the house. Nobody was waiting inside."
                : "La puerta estaba abierta. Ella volvió a la casa. Nadie la esperaba dentro."
            for (trial, steps) in [1, 2, 3, 4, 5, 6, 7, 8, 2, 4, 4, 4].enumerated() {
                let capture = Mutex((samples: [Float](), events: [Event](), first: Optional<Double>.none))
                await engine.setRandomSeed(42)
                let started = ProcessInfo.processInfo.systemUptime
                let voice = trial == 10 ? "alba" : "caro_davy"
                let style: PocketTTSDeliveryStyle = trial == 9 || trial == 10 ? .original : .calm
                try await engine.renderFrames(trial == 11 ? long : short, voiceID: "pocket-\(voice)-\(code)-v1",
                    chunking: .carefulReading, samplerSteps: steps, deliveryStyle: style,
                    onTextChunk: { event in
                        capture.withLock { state in
                            state.events.append(.init(text: event.text, start: event.startSample,
                                end: event.endSample, accepted: state.samples.count))
                        }
                    }, receive: { samples in
                        capture.withLock { state in
                            if state.first == nil { state.first = ProcessInfo.processInfo.systemUptime - started }
                            state.samples += samples
                        }
                    })
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let value = capture.withLock { $0 }
                XCTAssertFalse(value.samples.isEmpty)
                XCTAssertEqual(value.events.last?.end, value.samples.count)
                XCTAssertTrue(value.events.allSatisfy { $0.end == $0.accepted })
                _ = try save(value.samples, name: "pocket-\(code)-\(trial)-steps\(steps)", seconds: elapsed,
                    first: value.first ?? elapsed, events: value.events, output: output, baseline: baseline)
            }
            do {
                try await engine.renderFrames(short, voiceID: "pocket-caro_davy-\(code)-v1",
                    onTextChunk: { _ in XCTFail("Cancelled chunk was announced") }, receive: { _ in throw CancellationError() })
                XCTFail("Receiver cancellation did not propagate")
            } catch is CancellationError {}

            await engine.setRandomSeed(42)
            let start = ProcessInfo.processInfo.systemUptime
            let recovered = try await engine.synthesize(short, voiceID: "pocket-caro_davy-\(code)-v1", chunking: .carefulReading, deliveryStyle: .calm)
            _ = try save(recovered.samples, name: "pocket-\(code)-recovered", seconds: ProcessInfo.processInfo.systemUptime - start,
                         first: 0, events: [], output: output, baseline: baseline)
            await engine.unload()
            let unloaded = await engine.loadedLanguage
            XCTAssertNil(unloaded)
        }
    }

}
