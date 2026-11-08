import Foundation
import UIKit
import AVFoundation
import LibroxTTS

/// Real background-audio execution: genuine narrated PCM is playing while
/// additional, previously unrendered text is synthesized on CPU and queued.
@available(iOS 26.0, *)
@MainActor enum BackgroundRun {
    static var player: AVQueuePlayer?
    static func run(progress: (String) -> Void) async throws {
        let assets = Bundle.main.bundleURL.appendingPathComponent("Assets")
        let output = URL.documentsDirectory.appendingPathComponent("BackgroundResults")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = NarrationRenderer(compactDirectory: assets, harmonicSource: nil)
        let pipeline = NarrationPipeline()
        var grant: NarrationBackgroundGPUGrant?
        var rows: [[String: Any]] = []
        var rejectedUnownedGPU = false
        let arguments = ProcessInfo.processInfo.arguments
        let steps = arguments.contains("--one-step") ? 1 : arguments.contains("--four-steps") ? 4 : 8
        func save(_ stage: String, error: String? = nil) throws {
            var report: [String: Any] = ["stage": stage, "rows": rows, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "applicationState": UIApplication.shared.applicationState.rawValue, "samplerSteps": steps,
                "runtime": "max-background-beta5-candidate",
                "freshBuffer": arguments.contains("--fresh-buffer"),
                "controlledGrantRetirement": arguments.contains("--retire-grant"),
                "longPassage": arguments.contains("--long"),
                "rejectedUnownedGPU": rejectedUnownedGPU,
                "gpuSupported": NarrationBackgroundGPUGrant.isSupported, "gpuGranted": grant != nil]
            if let error { report["error"] = error }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("report.json"), options: .atomic)
        }
        do {
            do {
                try await renderer.load(.pocket, directory: assets, executionContext: .backgroundGPU)
            } catch { rejectedUnownedGPU = true }
            guard rejectedUnownedGPU else {
                throw NSError(domain: "MaxDeviceProbe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Unowned background GPU request was accepted"])
            }
            try save("preparingBuffer")
            progress("Preparing a real narration buffer before the background test…")
            try await renderer.load(.pocket, directory: assets, executionContext: .foreground)
            let bufferURL = output.appendingPathComponent("prebuffer.wav")
            if ProcessInfo.processInfo.arguments.contains("--fresh-buffer") || !FileManager.default.fileExists(atPath: bufferURL.path) {
            let prebuffer = try await pipeline.plan(DeviceRun.trials[1].text, model: .pocket, bookID: "background-test", chapterID: "prebuffer",
                narratorVoiceID: "pocket-george-en-v1", language: "en", pocketSampling: .init(temperature: 0.3, samplerSteps: steps))
            var buffered: [Float] = []
            for unit in prebuffer.units { buffered += try await renderer.render(unit) }
            try DeviceRun.writeWave(buffered, to: bufferURL)
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            // The sustained CPU trial starts with four real narrated passages cached
            // ahead, so resource-budget validation is not an audio-starvation test.
            let bufferedPassages = arguments.contains("--long") ? 4 : 1
            player = AVQueuePlayer(items: (0..<bufferedPassages).map { _ in AVPlayerItem(url: bufferURL) })
            player?.play()
            while UIApplication.shared.applicationState != .active { try await Task.sleep(for: .milliseconds(100)) }
            if ProcessInfo.processInfo.arguments.contains("--prefer-gpu") {
                grant = try await NarrationBackgroundGPUGrant.request(
                    identifier: "com.section9labs.MaxDeviceProbe.narration." + UUID().uuidString,
                    title: "Preparing Max narration", subtitle: "English and Spanish device test", totalUnitCount: 3)
            }
            try save("waitingForBackground")
            progress("Narration is playing. Background the app to test new generation.")
            let deadline = Date().addingTimeInterval(60)
            while UIApplication.shared.applicationState != .background {
                try Task.checkCancellation()
                guard Date() < deadline else { throw CocoaError(.userCancelled) }
                try await Task.sleep(for: .milliseconds(100))
            }
            // GPU work has finished. Replacing the backend must drop every GPU
            // graph and RNG reference before any background CPU generation.
            try await renderer.load(.pocket, directory: assets, executionContext: .background)
            let texts = arguments.contains("--long") ? [("en", "george", DeviceRun.trials[1].text)] : [
                ("en", "alba", "Behind the garden wall, a narrow path led to the river. Clara followed it slowly, listening to the water and wondering what the morning would bring."),
                ("es", "lola", "La puerta estaba abierta. Entró despacio y dejó las llaves sobre la mesa. Desde la cocina llegó una voz conocida, y entonces supo que no estaba sola."),
                ("en", "george", "James stood beside the bridge. He had kept his promise, and this time there would be no hurried goodbye. Together they watched the sunlight move across the river.")
            ]
            for (index, item) in texts.enumerated() {
                try Task.checkCancellation()
                let plan = try await pipeline.plan(item.2, model: .pocket, bookID: "background-test", chapterID: "cpu-\(index)",
                    narratorVoiceID: "pocket-\(item.1)-\(item.0)-v1", language: item.0,
                    pocketSampling: .init(temperature: 0.3, samplerSteps: steps))
                for unit in plan.units {
                    let before = UIApplication.shared.applicationState.rawValue
                    let playbackBefore = player?.currentTime().seconds ?? 0
                    let started = Date()
                    let samples: [Float]
                    var gpu = grant?.isValid == true
                    if let grant, gpu {
                        do {
                            if index == 0 && ProcessInfo.processInfo.arguments.contains("--retire-grant") {
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(500))
                                    await grant.finish(success: false)
                                }
                            }
                            samples = try await grant.withGPUWork {
                                try await renderer.load(.pocket, directory: assets, executionContext: .backgroundGPU)
                                return try await renderer.render(unit)
                            }
                        } catch NarrationBackgroundGPUGrant.GrantError.expired {
                            try Task.checkCancellation()
                            gpu = false
                            try await renderer.load(.pocket, directory: assets, executionContext: .background)
                            samples = try await renderer.render(unit)
                        }
                    } else {
                        try await renderer.load(.pocket, directory: assets, executionContext: .background)
                        samples = try await renderer.render(unit)
                    }
                    let elapsed = Date().timeIntervalSince(started)
                    let file = output.appendingPathComponent("background-\(index)-\(rows.count).wav")
                    try DeviceRun.writeWave(samples, to: file)
                    player?.insert(AVPlayerItem(url: file), after: nil)
                    rows.append(["language": item.0, "voice": unit.voiceID, "renderSeconds": elapsed,
                        "audioSeconds": Double(samples.count) / 24_000, "stateBefore": before,
                        "stateAfter": UIApplication.shared.applicationState.rawValue,
                        "playbackBefore": playbackBefore, "playbackAfter": player?.currentTime().seconds ?? 0,
                        "playerRate": player?.rate ?? 0, "footprintBytes": DeviceRun.footprint(),
                        "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                        "completedBackend": gpu ? "gpu" : "cpu"])
                    grant?.reportProgress(completedUnitCount: Int64(index + 1))
                    try save("generating")
                }
            }
            await renderer.unload()
            await grant?.finish(success: true)
            try save("complete")
            progress("Background rendering completed; generated speech remains queued.")
        } catch {
            await renderer.unload()
            await grant?.finish(success: false)
            try? save("failed", error: String(describing: error))
            throw error
        }
    }
}
