import CryptoKit
import Darwin
import Foundation
import KokoroCatalog
import MLX
import PocketTTSMLX
import Synchronization
import XCTest
@testable import PocketTTSCoreML

/// New sidecar evidence; existing public benchmark fields retain their meanings.
final class Release09BenchmarkTests: XCTestCase {
    private struct Event: Codable, Equatable { let text: String; let start: Int; let end: Int; let accepted: Int }
    private struct Row: Codable {
        let name: String; let wallSeconds: Double; let previewSeconds: Double?
        let firstAcceptedFrameSeconds: Double; let frameServiceP50: Double; let frameServiceP95: Double
        let sampledPeakFootprint: UInt64; let thermalStart: Int; let thermalEnd: Int
        let samples: Int; let sha256: String; let events: [Event]
    }
    private struct Capture {
        var samples: [Float] = []; var events: [Event] = []; var intervals: [Double] = []
        var first: Double?; var lastReturn: Double; var peak: UInt64 = 0
    }
    func testColdPreviewWarmSwitchAndBackpressure() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["LIBROX_09_OUTPUT"], let rootPath = env["LIBROX_09_ASSETS"] else {
            throw XCTSkip("Requires explicit benchmark assets/output")
        }
        if let metal = env["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: metal) }
        let backend = env["LIBROX_09_BACKEND"] ?? "coreml"
        let output = URL(fileURLWithPath: outputPath), root = URL(fileURLWithPath: rootPath)
        let baseline = env["LIBROX_09_BASELINE"].map { URL(fileURLWithPath: $0) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let core = PocketTTSCoreMLEngine(directory: root)
        let mlx = PocketTTSEngine(directory: root, backend: backend == "cpu" ? .cpu : .gpu)
        await mlx.setCPUBudgetFraction(nil)
        let observedPeak = Mutex<UInt64>(0)
        let observer: @Sendable (PocketTTSResourceSnapshot) -> Void = { s in observedPeak.withLock { $0 = max($0,s.footprintBytes) } }
        await core.setResourceObserver(observer); await mlx.setResourceObserver(observer)
        func unload() async { await core.unload(); await mlx.unload() }
        // Existing reading-corpus.json, first sentence excerpt of Alice, plus
        // the existing Spanish reading fixture. Fixed source, not invented timings.
        let book = "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do."
        let cases = [
            ("cold", "en", "alba", "The door was open.", false, false),
            ("preview", "en", "alba", "The door was open.", true, false),
            ("warm-0", "en", "alba", "The door was open.", false, false),
            ("warm-1", "en", "alba", "The door was open.", false, false),
            ("book", "en", "alba", book, false, false),
            ("voice-switch", "en", "caro_davy", "The door was open.", false, false),
            ("language-switch", "es", "alba", "La noche la pasó gozosa. ¡Oh ventajas de un buen propósito!", false, false),
            ("slow-receiver", "es", "alba", "La puerta estaba abierta.", false, true)
        ]
        var rows: [Row] = []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        for (name, language, voice, text, preview, slow) in cases {
            if name == "cold" || preview { await unload() }
            let voiceID = "pocket-\(voice)-\(language)-v1"
            var previewSeconds: Double?
            if preview {
                let start = ProcessInfo.processInfo.systemUptime
                if backend == "coreml" { _ = try await core.previewChunks(text, voiceID: voiceID, chunking: .carefulReading) }
                else { _ = try await mlx.previewChunks(text, voiceID: voiceID, chunking: .carefulReading) }
                previewSeconds = ProcessInfo.processInfo.systemUptime - start
            }
            await core.setRandomSeed(42); await mlx.setRandomSeed(42)
            observedPeak.withLock { $0 = 0 }
            let started = ProcessInfo.processInfo.systemUptime
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            let capture = Mutex(Capture(lastReturn: started))
            let receive: @Sendable ([Float]) throws -> Void = { frame in
                let now = ProcessInfo.processInfo.systemUptime
                capture.withLock {
                    $0.intervals.append(now - $0.lastReturn)
                    $0.samples += frame
                    if $0.first == nil { $0.first = now - started }
                }
                if slow { Thread.sleep(forTimeInterval: 0.002) }
                capture.withLock { $0.lastReturn = ProcessInfo.processInfo.systemUptime }
            }
            let event: @Sendable (PocketTTSChunkProgress) throws -> Void = { e in
                capture.withLock { $0.events.append(.init(text:e.text,start:e.startSample,end:e.endSample,accepted:$0.samples.count)) }
            }
            if backend == "coreml" {
                try await core.renderFrames(text, voiceID: voiceID, chunking: .carefulReading, samplerSteps: 4, onTextChunk: event, receive: receive)
            } else {
                try await mlx.renderFrames(text, voiceID: voiceID, chunking: .carefulReading, samplerSteps: 4, onTextChunk: event, receive: receive)
            }
            let seconds = ProcessInfo.processInfo.systemUptime - started
            let result = capture.withLock { $0 }, bytes = result.samples.withUnsafeBytes { Data($0) }
            let intervals = result.intervals.dropFirst().sorted()
            let row = Row(name:name,wallSeconds:seconds,previewSeconds:previewSeconds,
                firstAcceptedFrameSeconds:result.first ?? seconds,
                frameServiceP50:intervals.isEmpty ? 0 : intervals[intervals.count/2],
                frameServiceP95:intervals.isEmpty ? 0 : intervals[min(intervals.count-1,Int(Double(intervals.count)*0.95))],
                sampledPeakFootprint:observedPeak.withLock{$0},thermalStart:thermal,
                thermalEnd:ProcessInfo.processInfo.thermalState.rawValue,samples:result.samples.count,
                sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),events:result.events)
            if let baseline {
                XCTAssertEqual(bytes,try Data(contentsOf:baseline.appendingPathComponent(name+".f32")),name)
                let old = try JSONDecoder().decode(Row.self,from:Data(contentsOf:baseline.appendingPathComponent(name+".json")))
                XCTAssertEqual(row.events,old.events,name)
            }
            try bytes.write(to:output.appendingPathComponent(name+".f32"))
            try encoder.encode(row).write(to:output.appendingPathComponent(name+".json"))
            rows.append(row)
            try encoder.encode(rows).write(to:output.appendingPathComponent("report.json"))
        }
        await unload()
    }
}
