import Darwin
import Foundation
import LibroxTTS
import PocketTTSMLX
import KokoroCatalog
import AVFoundation
import MLX
@main struct Probe {
    struct Trial: Decodable {
        let assets: String
        let output: String
        let voiceID: String
        let text: String
        let temperature: Float
        let samplerSteps: Int
        let seed: UInt64
        let chunking: PocketTTSChunkingOptions
        let role: PocketTTSPassageRole
    }
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Pocket TTS: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let a = CommandLine.arguments
        if a.count == 3, a[1] == "--trial" {
            let trial = try JSONDecoder().decode(Trial.self, from: Data(contentsOf: URL(fileURLWithPath: a[2])))
            let engine = PocketTTSEngine(directory: URL(fileURLWithPath: trial.assets))
            // Load and initialize the model before seeding. This CLI process owns
            // exactly one engine; never reset global RNG inside the shared SDK.
            let chunks = try await engine.previewChunks(trial.text, voiceID: trial.voiceID,
                chunking: trial.chunking, role: trial.role)
            await engine.setRandomSeed(trial.seed)
            let started = Date()
            let audio = try await engine.synthesize(trial.text, voiceID: trial.voiceID,
                temperature: trial.temperature, chunking: trial.chunking, role: trial.role,
                samplerSteps: trial.samplerSteps)
            let elapsed = Date().timeIntervalSince(started)
            try write(audio, to: trial.output)
            let row: [String: Any] = ["samples": audio.samples.count, "sampleRate": audio.sampleRate,
                "renderSeconds": elapsed, "peak": audio.samples.map { abs($0) }.max() ?? 0,
                "runtime": PocketTTSEngine.runtimeIdentity,
                "chunks": chunks.map { ["text": $0.text, "tokens": $0.tokenCount,
                    "boundaryAfter": $0.boundaryAfter.rawValue, "startsNewPassage": $0.startsNewPassage] as [String: Any] }]
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        if a.count == 4, a[1] == "--download" {
            let directory = URL(fileURLWithPath: a[2])
            try await NarrationAssets.download(.pocket, to: directory, language: a[3])
            let manifest = try NarrationAssets.manifest(.pocket, language: a[3])
            print("Installed \(a[3]): \(manifest.installedFiles.count) verified files, \(manifest.downloadSize) bytes")
            return
        }
        if (5...7).contains(a.count), a[1] == "--plan" {
            let engine = PocketTTSEngine(directory: URL(fileURLWithPath: a[2]))
            let chunking = try a.count > 5 ? JSONDecoder().decode(PocketTTSChunkingOptions.self,
                from: Data(contentsOf: URL(fileURLWithPath: a[5]))) : .init()
            let role: PocketTTSPassageRole = a.count > 6 && a[6] == "dialogue" ? .dialogue : .narration
            let chunks = try await engine.previewChunks(a[4], voiceID: a[3], chunking: chunking, role: role)
            let rows: [[String: Any]] = chunks.map {
                ["text": $0.text, "tokens": $0.tokenCount, "boundaryAfter": $0.boundaryAfter.rawValue,
                 "startsNewPassage": $0.startsNewPassage]
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        guard (5...8).contains(a.count) else {
            print("pocket-tts-probe ASSET_ROOT VOICE_ID OUTPUT.wav TEXT [TEMPERATURE] [CHUNKING_JSON] [narration|dialogue]")
            print("pocket-tts-probe --plan ASSET_ROOT VOICE_ID TEXT [CHUNKING_JSON] [narration|dialogue]")
            return
        }
        let started = Date()
        let engine = PocketTTSEngine(directory: URL(fileURLWithPath: a[1]))
        let chunking = try a.count > 6 ? JSONDecoder().decode(PocketTTSChunkingOptions.self,
            from: Data(contentsOf: URL(fileURLWithPath: a[6]))) : .init()
        let role: PocketTTSPassageRole = a.count > 7 && a[7] == "dialogue" ? .dialogue : .narration
        let audio = try await engine.synthesize(a[4], voiceID: a[2], temperature: a.count > 5 ? Float(a[5]) ?? 0.3 : 0.3,
                                                chunking: chunking, role: role)
        try write(audio, to: a[3])
        print("samples=\(audio.samples.count) rate=\(audio.sampleRate) elapsed=\(Date().timeIntervalSince(started)) peak=\(audio.samples.map { abs($0) }.max() ?? 0)")
    }
    static func write(_ audio: PocketTTSEngine.Output, to path: String) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count))!
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
        try file.write(from: buffer)
    }
}
