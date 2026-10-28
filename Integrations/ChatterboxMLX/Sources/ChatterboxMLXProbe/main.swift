import Foundation
import AVFoundation
import CryptoKit
import ChatterboxCoreML
import LibroxChatterbox
import LibroxChatterboxMLX

@main struct DirectedProbe {
    enum Failure: Error { case arguments, invalidAudio }
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 9, let voiceID = UUID(uuidString: args[5]),
              ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0"
        else { throw Failure.arguments }
        let urls = args.prefix(5).map { URL(fileURLWithPath: $0) }
        let store = try ChatterboxVoiceStore(directory: urls[4])
        let saved = try await store.voice(voiceID), voice = try await store.conditioningFile(for: voiceID)
        let source = try String(contentsOfFile: args[6], encoding: .utf8)
        let out = URL(fileURLWithPath: args[7])
        guard !FileManager.default.fileExists(atPath: out.path) else { throw Failure.arguments }
        let units = try ChatterboxBookDirector.plan(source, language: args[8], narratorID: saved.id.uuidString,
            conditioningFiles: [saved.id.uuidString: voice], seed: 42)
        guard !units.isEmpty else { throw Failure.arguments }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        // Diagnostic opt-in only. Keep encoder/vocoder/watermark on the reviewed
        // CPU policy so this comparison changes CFM placement/padding alone.
        let aneCFM = ProcessInfo.processInfo.environment["CHATTERBOX_MLX_CFM_ANE"] == "1"
        let forcedPadding = ProcessInfo.processInfo.environment["CHATTERBOX_SYNTH_CFM_PAD"] == "1"
        let acousticProfile = aneCFM ? "cfm-ane-padded" : (forcedPadding ? "cfm-cpu-padded" : "cfm-cpu")
        let renderBegan = Date()
        if let value = ProcessInfo.processInfo.environment["CHATTERBOX_MLX_CACHE_BYTES"],
           let bytes = Int(value), bytes >= 0 {
            ChatterboxMLXRenderer.configureBufferCache(maximumBytes: bytes)
        }
        let renderer = try await ChatterboxMLXRenderer(weightsFile: urls[0], oracleFile: urls[1],
            modelDirectory: urls[2], defaultVoice: voice, watermarkDirectory: urls[3],
            acousticComputeUnits: .init(encoder: .cpuOnly, cfm: aneCFM ? .cpuAndNeuralEngine : .cpuOnly,
                                       vocoder: .cpuOnly, watermark: .cpuOnly))
        let modelLoadSeconds = Date().timeIntervalSince(renderBegan)
        let narrator = await renderer.makeNarrator()
        let memoryAfterLoad = memoryReport()
        var memoryWindows: [[String: Any]] = []
        let cache = try ChatterboxLookaheadCache(directory: out.appendingPathComponent("pcm-cache"))
        var cadence = ChatterboxConversationSession()
        var full: [Float] = [], reports: [[String: Any]] = []
        for base in stride(from: 0, to: units.count, by: 3) {
            let window = try (base..<min(units.count, base + 3)).map { i in
                try ChatterboxCacheUnit(index: i, request: units[i].request,
                    modelManifestSHA256: "3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0",
                    conditioningSHA256: saved.conditioningSHA256,
                    rendererProfile: ChatterboxMLXRenderer.profile + ":" + ChatterboxBookDirector.revision + ":" + acousticProfile)
            }
            let ready = try await cache.prepareWindow(window, using: narrator)
            memoryWindows.append(["last_unit": ready.last!.unit.index, "memory": memoryReport()])
            for value in ready {
                let index = value.unit.index, planned = units[index]
                guard var samples = try await cache.samples(for: value.unit) else { throw Failure.invalidAudio }
                let seam = try cadence.completeUnit(&samples, context: planned.timingContext)
                full += samples
                guard full.count <= 180 * 24_000 else { throw Failure.invalidAudio }
                reports.append(["index": index, "text": planned.request.text,
                    "range_location": planned.request.sourceContext!.range.location,
                    "range_length": planned.request.sourceContext!.range.length,
                    "voice_id": saved.id.uuidString, "exaggeration": planned.request.exaggeration,
                    "guidance": planned.request.guidance, "delivery": planned.performance.delivery.rawValue,
                    "evidence": planned.performance.evidence.source.rawValue,
                    "unmapped_named_delivery": planned.performance.chatterboxSuggestion.unmappedDelivery?.rawValue ?? "none",
                    "seam_kind": seam.decision.kind.rawValue, "inserted_samples": seam.insertedSamples])
                FileHandle.standardOutput.write(Data("Directed unit \(index + 1)/\(units.count) ready\n".utf8))
            }
        }
        try await narrator.unload()
        guard !full.isEmpty, full.allSatisfy(\.isFinite),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(full.count)),
              let channel = buffer.floatChannelData?[0] else { throw Failure.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(full.count)
        full.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        let wav = out.appendingPathComponent("spanish-librox-directed.wav")
        do { let writer = try AVAudioFile(forWriting: wav, settings: format.settings); try writer.write(from: buffer) }
        let report: [String: Any] = ["state": "complete", "profile": ChatterboxMLXRenderer.profile,
            "director_revision": ChatterboxBookDirector.revision, "voice": saved.name, "voice_id": saved.id.uuidString,
            "requested_acoustic_profile": acousticProfile,
            "model_load_seconds": modelLoadSeconds,
            "total_wall_seconds": Date().timeIntervalSince(renderBegan),
            "conditioning_sha256": saved.conditioningSHA256, "units": reports, "duration_seconds": Double(full.count) / 24_000,
            "peak": full.reduce(Float.zero) { max($0, abs($1)) }, "model_oracle_checked": true,
            "memory_after_load": memoryAfterLoad, "memory_windows": memoryWindows,
            "source_preserved": true, "quality_accepted": false,
            "scope": "Saved voice + Librox director/semantic cadence/current-plus-two cache + native MLX SDK; Mac diagnostic, requested CFM placement is not proof of actual device assignment"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("report.json"), options: .atomic)
    }

    private static func memoryReport() -> [String: Any] {
        let memory = ChatterboxMLXRenderer.memorySnapshot()
        return ["available_bytes": memory.availableBytes.map { NSNumber(value: $0) } as Any? ?? NSNull(),
                "mlx_active_bytes": memory.activeBytes, "mlx_cache_bytes": memory.cacheBytes,
                "mlx_peak_bytes": memory.peakBytes, "low_power_mode": memory.lowPowerMode,
                "thermal_state": memory.thermalState]
    }
}
