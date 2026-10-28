import Foundation
import AVFoundation
import LibroxChatterbox
import Darwin

@main struct Probe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("chatterbox-probe: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] {
            print("librox-chatterbox-probe --models DIR --watermark DIR --language en --text TEXT --output FILE.wav [--voice FILE.safetensors] [--seed N] [--max-tokens N] [--exaggeration F] [--cfg F] [--cpu]\nClone: --clone AUDIO --models DIR --output NEW.safetensors")
            return
        }
        var values: [String: String] = [:]; var cpu = false; var gpu = false; var padFlow = false; var index = 0
        let flags: Set<String> = ["--models", "--watermark", "--language", "--text", "--output", "--voice", "--seed", "--max-tokens", "--exaggeration", "--cfg", "--clone"]
        while index < args.count {
            let key = args[index]
            if key == "--cpu" { cpu = true; index += 1; continue }
            if key == "--gpu" { gpu = true; index += 1; continue }
            if key == "--pad-flow" { padFlow = true; index += 1; continue }
            guard flags.contains(key), index + 1 < args.count, values[key] == nil else { throw CLIError.arguments }
            values[key] = args[index + 1]; index += 2
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key] else { throw CLIError.arguments }; return value
        }
        let directory = URL(fileURLWithPath: try required("--models"))
        let output = URL(fileURLWithPath: try required("--output"))
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let narrator = ChatterboxNarrator()
        guard !(cpu && gpu) else { throw CLIError.arguments }
        if let reference = values["--clone"] {
            try await narrator.prepareReference(audioFile: URL(fileURLWithPath: reference), modelsDirectory: directory,
                                                outputFile: output, computePolicy: cpu ? .cpuOnly : (gpu ? .gpu : .neuralEngine))
            print("conditionals=\(output.path)"); return
        }
        func float(_ key: String, _ fallback: Float) throws -> Float {
            guard let raw = values[key] else { return fallback }
            guard let value = Float(raw) else { throw CLIError.arguments }; return value
        }
        let maxTokens = try values["--max-tokens"].map { raw in
            guard let number = Int(raw) else { throw CLIError.arguments }; return number
        } ?? 350
        let seed = try values["--seed"].map { raw in
            guard let number = UInt64(raw) else { throw CLIError.arguments }; return number
        }
        let request = try ChatterboxRequest(text: required("--text"), language: required("--language"),
            conditioningFile: values["--voice"].map { URL(fileURLWithPath: $0) },
            exaggeration: float("--exaggeration", 0.5), guidance: float("--cfg", 0.5), maxTokens: maxTokens, seed: seed)
        let began = Date()
        try await narrator.load(modelDirectory: directory,
            watermarkDirectory: URL(fileURLWithPath: required("--watermark")),
            computePolicy: cpu ? .cpuOnly : (gpu ? .gpu : .automatic),
            padFlowToMaximum: padFlow ? true : nil)
        let loaded = Date()
        print("selected_t3_compute_units=\(await narrator.selectedT3ComputeUnits ?? "unknown") (configuration, not residency)")
        let writer = try WAVWriter(url: output)
        try await narrator.stream(request) { chunk in try await writer.append(chunk) }
        let frames = await writer.frames
        print("sample_rate=24000 frames=\(frames) seconds=\(Double(frames)/24000) load_seconds=\(loaded.timeIntervalSince(began)) generation_seconds=\(Date().timeIntervalSince(loaded)) output=\(output.path)")
        try await narrator.unload()
    }
    enum CLIError: Error { case arguments }
}

private actor WAVWriter {
    let file: AVAudioFile
    let format: AVAudioFormat
    private(set) var frames: Int = 0
    init(url: URL) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }
    func append(_ chunk: ChatterboxAudioChunk) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw ChatterboxNarrationError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { data in channel.update(from: data.baseAddress!, count: data.count) }
        try file.write(from: buffer); frames += chunk.samples.count
    }
}
