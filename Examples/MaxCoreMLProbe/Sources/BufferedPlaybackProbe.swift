import AVFoundation
import Darwin
import Foundation
import LibroxTTS
import UIKit

/// A bounded, audible producer/consumer test through the public SDK. Generation
/// has no artificial CPU sleeps; real queued audio determines when it may run.
@MainActor final class BufferedPlaybackProbe {
    private let renderer = NarrationRenderer(compactDirectory: URL(fileURLWithPath: "/unused"), harmonicSource: nil)
    private let player = AVQueuePlayer()
    private var durations: [ObjectIdentifier: Double] = [:]
    private var rows: [[String: Any]] = []
    private var observations: [[String: Any]] = []
    private var totalEnqueued: Double = 0
    private var running = false
    private var sawPlaying = false
    private var stalls = 0
    private var wasStalled = false
    private var lastObservedSecond: Int = -1
    private var start: TimeInterval = 0
    private var nextFile = 0
    private let output: URL
    private let testSeconds: Double

    init(output: URL, testSeconds: Double = 600) { self.output = output; self.testSeconds = testSeconds }

    private func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private var queuedSeconds: Double {
        let items = player.items()
        let all = items.reduce(0.0) { $0 + (durations[ObjectIdentifier($1)] ?? 0) }
        let played = player.currentTime().seconds
        return max(0, all - (played.isFinite ? played : 0))
    }
    private func save(_ name: String, _ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(name + ".json"), options: .atomic)
    }
    private func enqueue(_ samples: [Float]) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        pcm.frameLength = pcm.frameCapacity
        samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let url = output.appendingPathComponent("speech-\(nextFile).wav"); nextFile += 1
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: pcm)
        let item = AVPlayerItem(url: url)
        let duration = Double(samples.count) / 24_000
        durations[ObjectIdentifier(item)] = duration
        totalEnqueued += duration
        player.insert(item, after: nil)
    }
    private func render(_ unit: BookNarrationUnit, phase: String) async throws -> [Float] {
        let began = ProcessInfo.processInfo.systemUptime, beganCPU = cpuTime()
        let samples = try await renderer.render(unit)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let audio = Double(samples.count) / 24_000
        rows.append(["phase": phase, "audioSeconds": audio, "wallSeconds": elapsed,
            "cpuSeconds": cpuTime() - beganCPU, "RTFx": audio / elapsed,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable])
        try save("progress", ["rows": rows, "observations": observations, "stalls": stalls, "complete": false])
        return samples
    }
    private func observe() {
        let now = ProcessInfo.processInfo.systemUptime - start
        let queue = queuedSeconds
        if player.timeControlStatus == .playing { sawPlaying = true }
        let stalled = sawPlaying && queue < 0.1
        if stalled && !wasStalled { stalls += 1 }
        wasStalled = stalled
        if Int(now) != lastObservedSecond {
            lastObservedSecond = Int(now)
            observations.append(["elapsedSeconds": now, "queuedSeconds": queue,
                "playedSeconds": totalEnqueued - queue, "timeControlStatus": player.timeControlStatus.rawValue,
                "applicationState": UIApplication.shared.applicationState.rawValue,
                "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                "availableBytes": os_proc_available_memory()])
        }
    }
    func run(bundle: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
        let installation = output.appendingPathComponent("installation")
        if !FileManager.default.fileExists(atPath: installation.path) {
            try FileManager.default.copyItem(at: bundle.appendingPathComponent("install"), to: installation)
        }
        try await Task.detached {
            try NarrationAssets.preparePocketNarratorPreset(in: installation, language: "en")
        }.value
        let text = "She rested her hand against the door. For a moment, she could almost hear his voice again. It was the small things she remembered: the way he folded the newspaper, the sound of his keys on the table, and the cup he always left beside the window. She waited. Nobody came."
        let preset = try PocketTTSNarratorPreset.defaultNarrator(language: "en")
        let plan = try await NarrationPipeline().plan(text, model: .pocket, bookID: "buffer-probe", chapterID: "1",
            narratorVoiceID: preset.voiceID, language: "en", pocketChunking: preset.chunking,
            pocketSampling: preset.sampling, pocketDelivery: preset.delivery)
        guard !plan.units.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        await renderer.setCPUBudget(fraction: nil)
        try await renderer.load(.pocket, directory: installation, executionContext: .foreground)
        var prebuffer: [Float] = []
        for pass in 0..<3 {
            guard UIApplication.shared.applicationState == .active else { throw NSError(domain: "BufferProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Foreground measurement was interrupted"]) }
            for unit in plan.units {
                let pcm = try await render(unit, phase: pass == 0 ? "foreground-cold" : "foreground-warm")
                if pass == 2 { prebuffer += pcm }
            }
        }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        try enqueue(prebuffer)
        player.play()
        defer {
            running = false; player.pause(); player.removeAllItems()
            try? AVAudioSession.sharedInstance().setActive(false)
        }
        try save("waiting-for-background", ["foregroundRows": rows, "initialBufferSeconds": queuedSeconds])
        let deadline = Date().addingTimeInterval(1800)
        while UIApplication.shared.applicationState != .background {
            try Task.checkCancellation()
            guard Date() < deadline else { throw NSError(domain: "BufferProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Background transition timed out"]) }
            // Continue playing genuine audio while waiting; no silent keepalive.
            if queuedSeconds < 12 { try enqueue(prebuffer) }
            try await Task.sleep(for: .milliseconds(200))
        }
        try await renderer.load(.pocket, directory: installation, executionContext: .background)
        start = ProcessInfo.processInfo.systemUptime
        let startedCPU = cpuTime(), initialPlayed = totalEnqueued - queuedSeconds
        running = true
        let monitor = Task {
            while running {
                observe()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        try save("background-start", ["initialBufferSeconds": queuedSeconds, "applicationState": UIApplication.shared.applicationState.rawValue])
        var filling = true, unitIndex = 0
        while ProcessInfo.processInfo.systemUptime - start < testSeconds {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.thermalState != .critical else { throw NSError(domain: "BufferProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Critical thermal state"]) }
            let queue = queuedSeconds
            if filling && queue >= 30 { filling = false }
            if !filling && queue <= 12 { filling = true }
            if !filling {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            let pcm = try await render(plan.units[unitIndex % plan.units.count], phase: "background")
            unitIndex += 1
            try enqueue(pcm)
            observe()
        }
        observe()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let played = totalEnqueued - queuedSeconds - initialPlayed
        let locked = observations.contains { ($0["protectedDataAvailable"] as? Bool) == false }
        let warm = rows.filter { ($0["phase"] as? String) == "foreground-warm" || ($0["phase"] as? String) == "background" }
        let throughputPassed = warm.allSatisfy { ($0["RTFx"] as? Double ?? 0) > 1 }
        try save("result", ["complete": true, "passed": stalls == 0 && locked && throughputPassed && played > elapsed - 2,
            "elapsedSeconds": elapsed, "playedSeconds": played, "processCPUSeconds": cpuTime() - startedCPU,
            "finalBufferSeconds": queuedSeconds, "stalls": stalls, "lockedObserved": locked,
            "allWarmUnitsFasterThanPlayback": throughputPassed, "rows": rows, "observations": observations,
            "policy": ["lowWaterSeconds": 12, "highWaterSeconds": 30, "artificialCPUBudget": "none"],
            "quality": ["temperature": 0.3, "samplerSteps": 4, "voice": "Caro Davy", "style": "Calm", "chunking": "carefulReading"]])
        await renderer.unload()
    }
}
