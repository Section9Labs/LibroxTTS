import Foundation
import AVFoundation
import Darwin
import LibroxCTNative

enum DeviceValidation {
    /// Exercise short/long prose, punctuation, languages and backend handoffs.
    /// Backend transitions here are explicit; they are not a locked-screen test.
    nonisolated static func passages(assets: URL, output: URL, backend: CTEngine.Backend) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = CTEngine(directory: assets, backend: backend)
        let start = Date(); try await engine.load()
        let loadSeconds = Date().timeIntervalSince(start)
        let cases = [
            ("one-word", "I.", "en"),
            ("short", "Yes. Come in.", "en"),
            ("spanish-short", "Sí. Aquí estoy.", "es"),
            ("dialogue", "Wait—did you hear that? No, she whispered. The house was quiet again, but neither of them moved.", "en"),
            ("numbers", "At 7:45, on the 12th of November, she found three letters and a note marked 2026.", "en"),
            ("long-en", "The road followed the river through the valley, past the abandoned station and the gardens where her grandfather had worked. She remembered the trees in summer, the sound of water under the bridge, and the promise they had made before the last train left.", "en"),
            ("long-es", "El camino seguía el río por el valle, junto a la estación abandonada y los jardines donde había trabajado su abuelo. Recordaba los árboles en verano, el agua bajo el puente y la promesa que habían hecho antes de que saliera el último tren.", "es")
        ]
        var reports: [[String: Any]] = []
        for (phase, selected) in [("foreground", backend), ("cpu-handoff", CTEngine.Backend.coreMLCPU), ("gpu-return", backend)] {
            let transition = Date(); try await engine.setBackend(selected)
            let transitionSeconds = Date().timeIntervalSince(transition)
            for (id, text, language) in cases {
                let start = Date()
                let result = try await engine.synthesize(text, language: language)
                let seconds = Date().timeIntervalSince(start)
                let audio = try CTDelivery.prepare(result.samples, sampleRate: 24_000)
                guard audio.samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
                reports.append(["phase":phase, "id":id, "backend":selected.rawValue,
                    "transitionSeconds":transitionSeconds, "synthesisSeconds":seconds,
                    "audioSeconds":Double(audio.samples.count)/24_000,
                    "latentLength":result.samples.count/3072, "graphSeconds":result.graphSeconds,
                    "physicalFootprintBytes":footprint(), "thermalState":ProcessInfo.processInfo.thermalState.rawValue])
                try JSONSerialization.data(withJSONObject: reports, options:[.prettyPrinted,.sortedKeys])
                    .write(to: output.appendingPathComponent("passages.json"), options:.atomic)
            }
        }
        await engine.unload()
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        try JSONSerialization.data(withJSONObject:["loadSeconds":loadSeconds,
            "peakResidentBytes":usage.ru_maxrss, "postUnloadPhysicalFootprintBytes":footprint(),
            "scope":"Foreground renders with explicit backend switches, not lock-screen execution"], options:.prettyPrinted)
            .write(to: output.appendingPathComponent("summary.json"))
    }
    /// Production render path: no tensor trace, file export or waveform comparison
    /// inside the timed interval. Records first render and five warm renders.
    nonisolated static func benchmark(assets: URL, fixtures: URL, output: URL, backend: CTEngine.Backend) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = CTEngine(directory: assets, backend: backend)
        let start = Date(); try await engine.load()
        let loadSeconds = Date().timeIntervalSince(start)
        struct Case: Decodable { let id: String; let text: String; let language: String }
        struct Layout: Decodable { let shape: [Int]; let dtype: CTTensor.Kind }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
        var reports: [[String: Any]] = []
        for item in cases {
            let folder = fixtures.appendingPathComponent(item.id)
            let layout = try JSONDecoder().decode([String: Layout].self, from: Data(contentsOf: folder.appendingPathComponent("layout.json")))
            guard let spec = layout["initial_latent"] else { throw CTError.invalidTensor("initial_latent") }
            let noise = try CTTensor(shape: spec.shape, kind: spec.dtype, data: Data(contentsOf: folder.appendingPathComponent("initial_latent.bin")))
            for repetition in 0..<6 {
                try Task.checkCancellation()
                let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
                let start = Date()
                let result = try await engine.synthesize(item.text, language: item.language, initialNoise: noise)
                let synthesisSeconds = Date().timeIntervalSince(start)
                let delivered = try CTDelivery.prepare(result.samples, sampleRate: 24_000)
                let totalSeconds = Date().timeIntervalSince(start)
                let audioSeconds = Double(delivered.samples.count) / 24_000
                reports.append(["id": item.id, "repetition": repetition, "warm": repetition > 0,
                    "synthesisSeconds": synthesisSeconds, "withDeliverySeconds": totalSeconds,
                    "audioSeconds": audioSeconds, "realTimeFactor": totalSeconds / audioSeconds,
                    "graphSeconds": result.graphSeconds, "physicalFootprintBytes": footprint(),
                    "thermalBefore": thermalBefore, "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue])
            }
        }
        await engine.unload()
        var usage = rusage()
        let hasUsage = getrusage(RUSAGE_SELF, &usage) == 0
        try JSONSerialization.data(withJSONObject: ["runtime": backend.identity, "loadSeconds": loadSeconds,
            "cases": reports, "peakResidentBytes": hasUsage ? usage.ru_maxrss : 0,
            "postUnloadPhysicalFootprintBytes": footprint(), "os": ProcessInfo.processInfo.operatingSystemVersionString],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("benchmark.json"))
    }
    nonisolated static func run(assets: URL, fixtures: URL, output: URL, backend: CTEngine.Backend) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
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
            reports.append(["id": item.id, "seconds": elapsed, "synthesisSeconds": synthesisSeconds, "audioSeconds": Double(result.samples.count)/44100,
                            "gainDB": nativeDelivery.gainDB, "loudnessLUFS": nativeDelivery.measuredLUFS, "graphSeconds": result.graphSeconds, "thermalState": ProcessInfo.processInfo.thermalState.rawValue, "physicalFootprintBytes": footprint(), "tensors": comparisons])
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
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
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
