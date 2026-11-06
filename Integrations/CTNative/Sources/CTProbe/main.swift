import Foundation
import AVFoundation
import Darwin
import LibroxCTNative

@main struct Probe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("CT probe failed: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else { throw CTError.invalidAssets("Usage: ct-native-probe ASSETS FIXTURES OUTPUT [coreMLCPU|coreMLGPU|coreMLGPUHeavy|coreMLNeuralEngine|coreMLAll]") }
        let assets = URL(fileURLWithPath: args[1]), fixtures = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let backend = CTEngine.Backend(rawValue: args.count > 4 ? args[4] : "coreMLCPU") else {
            throw CTError.invalidAssets("unknown diagnostic backend")
        }
        let engine = CTEngine(directory: assets, backend: backend)
        let start = Date(); try await engine.load()
        let loadSeconds = Date().timeIntervalSince(start)
        print("loaded in \(loadSeconds)s")
        struct Case: Decodable { let id: String; let text: String; let language: String }
        struct Layout: Decodable { let shape: [Int]; let dtype: CTTensor.Kind }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
        var reports: [[String: Any]] = []
        for item in cases {
            let folder = fixtures.appendingPathComponent(item.id)
            let layout = try JSONDecoder().decode([String: Layout].self, from: Data(contentsOf: folder.appendingPathComponent("layout.json")))
            func tensor(_ name: String) throws -> CTTensor {
                guard let spec = layout[name] else { throw CTError.invalidTensor(name) }
                return try CTTensor(shape: spec.shape, kind: spec.dtype, data: Data(contentsOf: folder.appendingPathComponent(name + ".bin")))
            }
            let start = Date()
            let result = try await engine.synthesize(item.text, language: item.language, initialNoise: tensor("initial_latent"), captureTrace: true)
            let synthesisSeconds = Date().timeIntervalSince(start)
            var comparisons: [String: Any] = [:]
            for name in layout.keys.sorted() {
                guard let actual = result.trace[name] else { throw CTError.invalidTensor("missing " + name) }
                let expected = try tensor(name)
                guard actual.shape == expected.shape, actual.kind == expected.kind else { throw CTError.invalidTensor("shape " + name) }
                if expected.kind == .int64 {
                    comparisons[name] = ["exact": actual.data == expected.data]
                    guard actual.data == expected.data else { throw CTError.invalidTensor("token mismatch") }
                } else {
                    let a = try actual.floats(), b = try expected.floats()
                    var maxError: Double = 0, error: Double = 0, energy: Double = 0
                    for (x,y) in zip(a,b) { let d = Double(x)-Double(y); maxError = max(maxError,abs(d)); error += d*d; energy += Double(y)*Double(y) }
                    comparisons[name] = ["exact": actual.data == expected.data, "maxAbsoluteError": maxError,
                        "rmse": sqrt(error / Double(a.count)), "snrDB": error == 0 ? 999 : 10 * log10(energy / error)]
                }
                try actual.data.write(to: output.appendingPathComponent(item.id + "-" + name + ".bin"))
            }
            let nativeDelivery = try CTDelivery.prepare(result.samples, sampleRate: 44_100)
            let appDelivery = try CTDelivery.prepare(result.samples, sampleRate: 24_000)
            try writeWave(nativeDelivery.samples, rate: 44_100, to: output.appendingPathComponent(item.id + "-native44.wav"))
            try writeWave(appDelivery.samples, rate: 24_000, to: output.appendingPathComponent(item.id + "-app24.wav"))
            let elapsed = Date().timeIntervalSince(start)
            reports.append(["id": item.id, "seconds": elapsed, "synthesisSeconds": synthesisSeconds,
                            "audioSeconds": Double(result.samples.count)/44100,
                            "gainDB": nativeDelivery.gainDB, "loudnessLUFS": nativeDelivery.measuredLUFS, "graphSeconds": result.graphSeconds, "tensors": comparisons])
            print("\(item.id): \(elapsed)s; waveform \(comparisons["waveform"]!)")
        }
        var usage = rusage()
        let hasUsage = getrusage(RUSAGE_SELF, &usage) == 0
        try JSONSerialization.data(withJSONObject: ["runtime": backend.identity, "cases": reports,
            "loadSeconds": loadSeconds, "peakResidentBytes": hasUsage ? usage.ru_maxrss : 0,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemory": ProcessInfo.processInfo.physicalMemory], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("parity.json"))
        await engine.unload()
    }
    static func writeWave(_ samples: [Float], rate: Int, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw CTError.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

}
