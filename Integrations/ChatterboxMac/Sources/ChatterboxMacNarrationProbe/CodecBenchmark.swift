#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import ChatterboxMacAcousticAudit

/// Codec-only comparison on pinned retained PCM. No model construction/forward.
enum MacCodecBenchmark {
    struct Input: Decodable { let language, path, sha256: String; let frames: Int64 }
    struct Configuration: Decodable { let inputs: [Input]; let outputDirectory: String }
    struct Attempt: Codable {
        let language, codec, state: String
        let repetition: Int
        let export: NativeAudioExportReport?
        let observedBitRate: UInt32?
        let failure: String?
    }
    struct Summary: Codable {
        let language, codec: String
        let successfulAttempts: Int
        let medianSeconds: Double?
        let bytes: Int?
        let audioSeconds: Double
    }
    struct Report: Codable {
        let state: String
        let neuralRenders: Int
        let cloudUploadMeasured, newFormatIntegrationApproved: Bool
        let attempts: [Attempt]
        let summaries: [Summary]
    }
    static func run(configuration path: String) throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 65537) ?? Data()
        guard bytes.count <= 65536 else { throw AcousticInventoryError.input }
        let c = try JSONDecoder().decode(Configuration.self, from: bytes)
        guard c.inputs.count == 2, Set(c.inputs.map(\.language)) == ["en", "es"] else { throw AcousticInventoryError.input }
        let root = URL(fileURLWithPath: c.outputDirectory)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw AcousticInventoryError.input }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var attempts: [Attempt] = [], summaries: [Summary] = []
        for input in c.inputs {
            try healthy()
            let file = URL(fileURLWithPath: input.path)
            guard try MacNarrationProbe.hash(file) == input.sha256 else { throw AcousticInventoryError.identity }
            let reader = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard (1...Int64(120 * 24000)).contains(input.frames), reader.length == input.frames,
                  reader.processingFormat.sampleRate == 24000, reader.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 65536)
            else { throw AcousticInventoryError.input }
            var samples: [Float] = []; samples.reserveCapacity(Int(input.frames))
            while samples.count < input.frames {
                try healthy()
                try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(65536, Int(input.frames) - samples.count)))
                guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { throw AcousticInventoryError.input }
                samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            }
            guard reader.framePosition == reader.length, samples.count == input.frames,
                  samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw AcousticInventoryError.input }
            var failed: Set<String> = []
            let codecs = NativeAudioExport.Codec.allCases
            for repetition in 0..<3 {
                let order = Array(codecs[repetition...]) + Array(codecs[..<repetition])
                for codec in order where !failed.contains(codec.rawValue) {
                    try healthy()
                    let destination = root.appendingPathComponent(input.language + "-" + codec.rawValue + "-" + String(repetition) + "." + codec.fileExtension)
                    do {
                        let output = try NativeAudioExport.write(samples, to: destination, codec: codec)
                        attempts.append(.init(language: input.language, codec: codec.rawValue, state: "decoded-verified",
                            repetition: repetition, export: output, observedBitRate: bitRate(destination), failure: nil))
                    } catch {
                        try healthy() // Cancellation/resources stop the entire program.
                        failed.insert(codec.rawValue)
                        attempts.append(.init(language: input.language, codec: codec.rawValue, state: "rejected",
                            repetition: repetition, export: nil, observedBitRate: nil, failure: String(describing: error)))
                    }
                    try MacNarrationProbe.json(attempts).write(to: root.appendingPathComponent("attempts-incomplete.json"), options: .atomic)
                }
            }
            for codec in codecs {
                let values = attempts.filter { $0.language == input.language && $0.codec == codec.rawValue }.compactMap(\.export)
                let times = values.map(\.seconds).sorted()
                summaries.append(.init(language: input.language, codec: codec.rawValue, successfulAttempts: values.count,
                    medianSeconds: times.isEmpty ? nil : times[times.count/2], bytes: values.first?.bytes,
                    audioSeconds: Double(input.frames)/24000))
            }
        }
        try healthy()
        try MacNarrationProbe.json(Report(state: "complete-codec-comparison-only", neuralRenders: 0,
            cloudUploadMeasured: false, newFormatIntegrationApproved: false, attempts: attempts, summaries: summaries))
            .write(to: root.appendingPathComponent("report.json"), options: .atomic)
    }
    static func healthy() throws {
        try Task.checkCancellation()
        let p = ProcessInfo.processInfo
        guard !p.isLowPowerModeEnabled, p.thermalState != .serious, p.thermalState != .critical else { throw AcousticInventoryError.unsafeResource }
    }
    static func bitRate(_ url: URL) -> UInt32? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var rate: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}
#endif
