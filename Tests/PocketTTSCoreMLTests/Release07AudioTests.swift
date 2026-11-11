import Foundation
import CryptoKit
import Synchronization
import XCTest
import KokoroCatalog
import PocketTTSCoreML
import LibroxCTNative

/// Opt-in baseline/candidate comparison. PCM stays local; hashes and timings
/// are review receipts. Missing assets skip ordinary package tests explicitly.
final class Release07AudioTests: XCTestCase {
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

    func testPocketPCMAndChunkContractAgainst062() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LIBROX_07_POCKET_ASSETS"], let outputPath = env["LIBROX_07_AUDIO_OUTPUT"] else {
            throw XCTSkip("Requires verified local Pocket assets and an explicit evidence destination")
        }
        let root = URL(fileURLWithPath: path), output = URL(fileURLWithPath: outputPath)
        let baseline = env["LIBROX_07_AUDIO_BASELINE"].map { URL(fileURLWithPath: $0) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for code in ["en", "es"] { try PocketTTSCoreMLAssets.prepare(in: root, language: code) }
        let engine = PocketTTSCoreMLEngine(directory: root)
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
            let retired = await engine.loadedLanguage
            XCTAssertNil(retired)
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

    func testPlusTraceAndPCMContractAgainst062() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LIBROX_07_CT_ASSETS"], let outputPath = env["LIBROX_07_AUDIO_OUTPUT"] else {
            throw XCTSkip("Requires verified Plus assets and an explicit evidence destination")
        }
        let output = URL(fileURLWithPath: outputPath)
        let baseline = env["LIBROX_07_AUDIO_BASELINE"].map { URL(fileURLWithPath: $0) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = CTEngine(directory: URL(fileURLWithPath: path), backend: .coreMLCPU)
        try await engine.load()
        for (code, text) in [("en", "The door was open."), ("es", "La puerta estaba abierta.")] {
            let noiseURL = (baseline ?? output).appendingPathComponent("plus-\(code)-noise.f32")
            let shapeURL = (baseline ?? output).appendingPathComponent("plus-\(code)-noise-shape.json")
            let noise: CTTensor?
            if baseline != nil {
                noise = try CTTensor(shape: JSONDecoder().decode([Int].self, from: Data(contentsOf: shapeURL)),
                                     kind: .float32, data: Data(contentsOf: noiseURL))
            } else { noise = nil }
            let traced = try await engine.synthesize(text, language: code, initialNoise: noise, captureTrace: true)
            let waveform = try XCTUnwrap(traced.trace["waveform"])
            XCTAssertEqual(waveform.shape, [traced.samples.count])
            XCTAssertEqual(waveform.data, traced.samples.withUnsafeBytes { Data($0) })
            let frozenNoise = try XCTUnwrap(traced.trace["initial_latent"])
            if baseline == nil {
                try frozenNoise.data.write(to: noiseURL, options: .withoutOverwriting)
                try JSONEncoder().encode(frozenNoise.shape).write(to: shapeURL, options: .withoutOverwriting)
            }
            for trial in 0..<3 {
                let start = ProcessInfo.processInfo.systemUptime
                let normal = try await engine.synthesize(text, language: code, initialNoise: frozenNoise)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                XCTAssertTrue(normal.trace.isEmpty)
                XCTAssertEqual(normal.samples, traced.samples)
                _ = try save(normal.samples, name: "plus-\(code)-\(trial)", seconds: elapsed,
                             first: 0, events: [], output: output, baseline: baseline)
            }
        }
        await engine.unload()
    }
}
