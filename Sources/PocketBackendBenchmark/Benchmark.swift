import Foundation
import Darwin
import AVFoundation
import PocketTTSMLX
import PocketTTSCoreML
import KokoroCatalog
import KokoroNarration

public enum PocketBackendBenchmark {
    public struct Request: Codable, Sendable {
        public var backend: String
        public var language: String
        public var repetitions: Int
        public var steps: Int
        public var temperature: Float
        public var seed: UInt64
        public var text: String
        public var voiceID: String
        public var style: PocketTTSDeliveryStyle
        public init(backend: String, language: String = "en", repetitions: Int = 3,
                    steps: Int = 4, temperature: Float = 0.3, seed: UInt64 = 42,
                    text: String = "She rested her hand against the door. For a moment, she could almost hear his voice again. It was the small things she remembered: the way he folded the newspaper, the sound of his keys on the table, and the cup he always left beside the window. She waited. Nobody came.",
                    voiceID: String = "pocket-caro_davy-en-v1", style: PocketTTSDeliveryStyle = .calm) {
            self.backend = backend; self.language = language; self.repetitions = repetitions
            self.steps = steps; self.temperature = temperature; self.seed = seed
            self.text = text; self.voiceID = voiceID; self.style = style
        }
    }
    public struct Row: Codable, Sendable {
        public let iteration: Int
        public let coldGeneration: Bool
        public let renderSeconds: Double
        public let firstAudioSeconds: Double
        public let audioSeconds: Double
        public let realTimeFactor: Double
        public let samples: Int
        public let peakPhysicalFootprintBytes: UInt64
        public let thermalStart: Int
        public let thermalEnd: Int
    }
    struct Report: Codable {
        let request: Request
        let runtime: String
        let machine: String
        let operatingSystem: String
        let loadSeconds: Double
        let chunks: [String]
        let tokenCounts: [Int]
        var rows: [Row]
        var complete: Bool
    }
    final class Capture: @unchecked Sendable {
        let lock = NSLock()
        let start = ProcessInfo.processInfo.systemUptime
        var first: Double?
        var samples: [Float] = []
        var peak: UInt64 = footprint()
        func append(_ frame: [Float]) {
            lock.lock(); defer { lock.unlock() }
            if first == nil { first = ProcessInfo.processInfo.systemUptime - start }
            samples += frame
            if samples.count % (1920 * 25) == 0 { peak = max(peak, footprint()) }
        }
    }
    public static func run(_ request: Request, assets: URL, models: URL, output: URL,
                           onTrial: (@Sendable (URL) async throws -> Void)? = nil) async throws -> [Row] {
        guard ["mlx", "mlx-cpu", "coreml", "coreml-cpu", "coreml-ane", "coreml-all"].contains(request.backend), (1...20).contains(request.repetitions) else {
            throw NSError(domain: "Benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid backend or repetition count"])
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let isMLX = request.backend.hasPrefix("mlx")
        let mlx = PocketTTSEngine(directory: assets, backend: request.backend == "mlx-cpu" ? .cpu : .gpu)
        let core = PocketTTSCoreMLEngine(directory: assets, modelsDirectory: models,
            placement: request.backend == "coreml-cpu" ? .cpu : request.backend == "coreml-ane" ? .cpuANE : request.backend == "coreml-all" ? .all : .cpuGPU)
        let chunking = PocketTTSChunkingOptions.carefulReading
        let loadStart = ProcessInfo.processInfo.systemUptime
        let chunks = try await isMLX
            ? mlx.previewChunks(request.text, voiceID: request.voiceID, chunking: chunking)
            : core.previewChunks(request.text, voiceID: request.voiceID, chunking: chunking)
        var report = Report(request: request, runtime: isMLX ? PocketTTSEngine.runtimeIdentity : PocketTTSCoreMLEngine.runtimeIdentity,
            machine: machine(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            loadSeconds: ProcessInfo.processInfo.systemUptime - loadStart, chunks: chunks.map(\.text), tokenCounts: chunks.map(\.tokenCount), rows: [], complete: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for iteration in 0...request.repetitions {
            try Task.checkCancellation()
            let capture = Capture()
            let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
            if isMLX {
                await mlx.setRandomSeed(request.seed)
                try await mlx.renderFrames(request.text, voiceID: request.voiceID, temperature: request.temperature,
                    chunking: chunking, samplerSteps: request.steps, deliveryStyle: request.style, receive: capture.append)
            } else {
                await core.setRandomSeed(request.seed)
                try await core.renderFrames(request.text, voiceID: request.voiceID, temperature: request.temperature,
                    chunking: chunking, samplerSteps: request.steps, deliveryStyle: request.style, receive: capture.append)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - capture.start
            let duration = Double(capture.samples.count) / 24_000
            let row = Row(iteration: iteration, coldGeneration: iteration == 0, renderSeconds: elapsed,
                firstAudioSeconds: capture.first ?? elapsed, audioSeconds: duration, realTimeFactor: duration / elapsed,
                samples: capture.samples.count, peakPhysicalFootprintBytes: max(capture.peak, footprint()),
                thermalStart: thermalStart, thermalEnd: ProcessInfo.processInfo.thermalState.rawValue)
            let wav = output.appendingPathComponent("trial-\(iteration).wav")
            try writeWAV(capture.samples, to: wav)
            report.rows.append(row)
            try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
            try await onTrial?(wav)
            print("\(request.backend) trial=\(iteration) render=\(elapsed) audio=\(duration) RTFx=\(row.realTimeFactor) first=\(row.firstAudioSeconds)")
        }
        report.complete = true
        try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        await mlx.unload(); await core.unload()
        return report.rows
    }
    static func machine() -> String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
