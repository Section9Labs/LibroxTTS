import Foundation
import Testing
import MLX
import Darwin
import Synchronization
@testable import PocketTTSMLX

/// Run in separate processes/checkouts; PCM files permit exact release comparison.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_COMPARISON_OUTPUT"] != nil))
func releaseMemorySpeedAndPCMComparison() async throws {
    PocketTestMetal.configure()
    let env = ProcessInfo.processInfo.environment
    let root = URL(fileURLWithPath: env["POCKET_COMPARISON_OUTPUT"]!)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let backend: PocketTTSEngine.Backend = env["POCKET_COMPARISON_BACKEND"] == "cpu" ? .cpu : .gpu
    let broad = env["POCKET_COMPARISON_ALL_LANGUAGES"] == "1"
    let cases = [
        ("en", "pocket-alba-en-v1", "The road followed the river through the valley. At the bridge, she stopped to listen."),
        ("es", "pocket-alba-es-v1", "El camino seguía el río por el valle. Al llegar al puente, se detuvo a escuchar.")
    ] + (broad ? [
        ("de", "pocket-alba-de-v1", "Der Weg führte am Fluss entlang. An der Brücke blieb sie stehen und lauschte."),
        ("fr", "pocket-alba-fr-v1", "Le chemin suivait la rivière. Au pont, elle s'arrêta pour écouter les oiseaux."),
        ("it", "pocket-alba-it-v1", "Il sentiero seguiva il fiume. Vicino al ponte si fermò ad ascoltare gli uccelli."),
        ("pt", "pocket-alba-pt-v1", "O caminho seguia o rio. Perto da ponte, ela parou para ouvir os pássaros."),
        ("nl", "pocket-alba-nl-v1", "Het pad volgde de rivier. Bij de brug bleef ze staan om naar de vogels te luisteren.")
    ] : [])
    let engine = PocketTTSEngine(directory: URL(fileURLWithPath: env["POCKET_ASSETS"]!), backend: backend)
    for (language, voice, text) in cases {
        let text = env["POCKET_COMPARISON_LONG"] == "1" ? Array(repeating: text, count: 8).joined(separator: " ") : text
        for steps in broad ? [8] : [1, 2, 4, 8] {
            // Separate warmup/first load from steady-state generation measurements.
            Memory.clearCache()
            Memory.peakMemory = 0
            let loadStarted = ProcessInfo.processInfo.systemUptime
            _ = try await engine.previewChunks(text, voiceID: voice)
            if steps == 1 {
                print("LOAD language=\(language) seconds=\(ProcessInfo.processInfo.systemUptime - loadStarted) peak=\(Memory.peakMemory) active=\(Memory.activeMemory)")
            }
            for repetition in 0..<(env["POCKET_COMPARISON_LONG"] == "1" || broad ? 1 : 3) {
                await engine.setRandomSeed(42)
                Memory.clearCache()
                Memory.peakMemory = 0
                let started = ProcessInfo.processInfo.systemUptime
                let trace = env["POCKET_COMPARISON_TRACE"] == "1"
                let stats = Mutex((samples: [Float](), cache: 0, active: 0, footprint: UInt64(0)))
                let samples: [Float]
                if trace {
                    try await engine.renderFrames(text, voiceID: voice, temperature: 0.3, samplerSteps: steps) { frame in
                        stats.withLock {
                            $0.samples += frame
                            $0.cache = max($0.cache, Memory.cacheMemory)
                            $0.active = max($0.active, Memory.activeMemory)
                            var info = task_vm_info_data_t()
                            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
                            let result = withUnsafeMutablePointer(to: &info) {
                                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                                }
                            }
                            if result == KERN_SUCCESS { $0.footprint = max($0.footprint, info.phys_footprint) }
                        }
                    }
                    samples = stats.withLock { $0.samples }
                } else {
                    samples = try await engine.synthesize(text, voiceID: voice, temperature: 0.3, samplerSteps: steps).samples
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let name = "\(language)-\(steps)-\(repetition)"
                try samples.withUnsafeBytes { try Data($0).write(to: root.appendingPathComponent(name + ".pcm")) }
                let row: [String: Any] = ["case": name, "backend": backend.rawValue, "traced": trace,
                    "renderSeconds": elapsed, "audioSeconds": Double(samples.count) / 24_000,
                    "activeBytes": Memory.activeMemory, "peakBytes": Memory.peakMemory,
                    "maxFrameCacheBytes": stats.withLock { $0.cache },
                    "maxFrameActiveBytes": stats.withLock { $0.active },
                    "maxFrameFootprintBytes": stats.withLock { $0.footprint }]
                print("COMPARISON " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            }
        }
    }
    await engine.unload()
}
