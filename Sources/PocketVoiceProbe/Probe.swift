import AVFoundation
import Foundation
import LibroxTTS
import PocketTTSCoreML
import PocketTTSMLX
import MLX

/// Developer smoke tool; no voice recordings or states are bundled in the SDK.
private final class VoiceFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Float] = []
    func append(_ values: [Float]) { lock.withLock { frames += values } }
    var samples: [Float] { lock.withLock { frames } }
}

@main struct PocketVoiceProbe {
    struct Request: Decodable {
        let package: String
        let store: String
        let assets: String
        let output: String
        let text: String
        /// renderer = production platform routing; mlx/coreml = explicit backend.
        let backend: String
        let models: String?
        let seed: UInt64?
        let chunking: PocketTTSChunkingOptions?
    }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        if args.count == 7, args[1] == "package" {
            let language = args[4]
            guard let model = try PocketTTSCatalog.manifest(language: language).installedFiles.first(where: {
                $0.path == "\(language)/model.safetensors"
            }) else { throw PocketTTSImportedVoice.ImportError.incompatibleModel }
            let bytes = try PocketTTSImportedVoice.package(state: Data(contentsOf: URL(fileURLWithPath: args[2])),
                metadata: .init(name: args[3], language: language, modelIdentity: PocketTTSCatalog.identity,
                    modelSHA256: model.sha256, attribution: args[6]))
            let output = URL(fileURLWithPath: args[5])
            try bytes.write(to: output, options: .atomic)
            let voice = try PocketTTSImportedVoice.inspect(at: output)
            print("\(voice.name): \(voice.id) (\(bytes.count) bytes, \(voice.referenceFrames) frames)")
            return
        }
        guard args.count == 3, args[1] == "render" else {
            print("pocket-voice-probe package STATE NAME LANGUAGE OUTPUT ATTRIBUTION\npocket-voice-probe render REQUEST.json")
            return
        }
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        guard ["renderer", "renderer-stream", "mlx", "coreml"].contains(request.backend) else { throw PocketTTSError.invalidAssets }
        if let path = ProcessInfo.processInfo.environment["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
        let storeURL = URL(fileURLWithPath: request.store)
        let imported = try await PocketTTSVoiceStore(directory: storeURL).importVoice(from: URL(fileURLWithPath: request.package))
        // Exercise relaunch/reopen, then use the exact persisted ID in planning and rendering.
        let voices = try await PocketTTSVoiceStore(directory: storeURL).voices()
        guard let voice = voices.first(where: { $0.id == imported.id }) else { throw PocketTTSError.invalidVoice }
        let plan = try await NarrationPipeline().plan(request.text, model: .pocket, bookID: "voice-import-probe",
            chapterID: "1", narratorVoiceID: voice.id, language: voice.language,
            pocketChunking: request.chunking, importedVoices: voices)
        let assets = URL(fileURLWithPath: request.assets), start = Date()
        var samples: [Float] = []
        if request.backend.hasPrefix("renderer") {
            let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil, importedVoices: voices)
            try await renderer.load(.pocket, directory: assets, executionContext: .foreground)
            for unit in plan.units {
                if request.backend == "renderer-stream" {
                    let capture = VoiceFrames()
                    try await renderer.renderPocketFrames(unit) { capture.append($0) }
                    samples += capture.samples
                } else { samples += try await renderer.render(unit) }
            }
            await renderer.unload()
        } else if request.backend == "mlx" {
            let engine = PocketTTSEngine(directory: assets, importedVoices: voices)
            await engine.setRandomSeed(request.seed ?? 42)
            for unit in plan.units { samples += try await engine.synthesize(unit.synthesisText, voiceID: unit.voiceID,
                chunking: unit.pocketChunking ?? .init()).samples }
            await engine.unload()
        } else {
            let engine = PocketTTSCoreMLEngine(directory: assets,
                modelsDirectory: request.models.map { URL(fileURLWithPath: $0) }, importedVoices: voices)
            await engine.setRandomSeed(request.seed ?? 42)
            for unit in plan.units { samples += try await engine.synthesize(unit.synthesisText, voiceID: unit.voiceID,
                chunking: unit.pocketChunking ?? .init()).samples }
            await engine.unload()
        }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else { throw PocketTTSError.invalidAudio }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: request.output), settings: format.settings)
        try file.write(from: buffer)
        let row: [String: Any] = ["name": voice.name, "id": voice.id, "packageSHA256": voice.sha256,
            "referenceFrames": voice.referenceFrames, "backend": request.backend, "units": plan.units.count,
            "audioSeconds": Double(samples.count) / 24_000, "wallSeconds": Date().timeIntervalSince(start),
            "peak": samples.map { abs($0) }.max()!, "text": request.text]
        let json = try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: request.output + ".json"))
        print(String(decoding: json, as: UTF8.self))
    }
}
