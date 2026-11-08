import SwiftUI
import UIKit
import AVFoundation
import LibroxTTS
import Darwin
import os

@main struct MaxDeviceProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = "Ready to test Max at eight sampler steps"
    @State private var job: Task<Void, Never>?
    @State private var player: AVAudioPlayer?
    var body: some View {
        VStack(spacing: 24) {
            Text("Max Device Test").font(.largeTitle)
            Text(status).textSelection(.enabled)
            Button("Run device tests", action: run).disabled(job != nil)
            Button("Play English result") { play("english-tender-8") }
            Button("Play Spanish result") { play("spanish-8") }
        }.padding().task { if ProcessInfo.processInfo.arguments.contains("--run") { run() } }
        .onChange(of: phase) { _, value in
            UIApplication.shared.isIdleTimerDisabled = value == .active && job != nil
            if value != .active && !ProcessInfo.processInfo.arguments.contains("--background") { job?.cancel() }
        }
    }
    private func run() {
        guard job == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        job = Task {
            do {
                if #available(iOS 26.0, *), ProcessInfo.processInfo.arguments.contains("--background") {
                    try await BackgroundRun.run { status = $0 }
                } else {
                    try await DeviceRun.run { status = $0 }
                }
                status = "Completed. Audio and measurements saved in Files."
            } catch { status = "Stopped: \(error.localizedDescription)" }
            UIApplication.shared.isIdleTimerDisabled = false
            job = nil
        }
    }
    private func play(_ name: String) {
        do {
            player = try AVAudioPlayer(contentsOf: URL.documentsDirectory.appendingPathComponent("Results/\(name).wav"))
            player?.play()
        } catch { status = error.localizedDescription }
    }
}

enum DeviceRun {
    struct Trial: Sendable {
        let id: String
        let language: String
        let voice: String
        let steps: Int
        let characters: Bool
        let text: String
    }
    struct Measurement: Codable {
        let trial: String
        let unit: Int
        let text: String
        let voice: String
        let steps: Int
        let renderSeconds: Double
        let audioSeconds: Double
        let peak: Float
        let footprintBytes: UInt64
        let thermalState: Int
        let cacheIdentity: String
    }
    struct Report: Codable {
        let sdkCommit: String
        let os: String
        let physicalMemory: UInt64
        let completed: Bool
        let error: String?
        let measurements: [Measurement]
    }
    static let logger = Logger(subsystem: "com.section9labs.MaxDeviceProbe", category: "validation")
    static let tender = "She sat beside him and waited until his breathing grew quiet. There was no need to hurry. After all those years, they had finally found their way home. Outside, the rain softened to a whisper against the glass."
    static let dialogue = "Clara was her sister. James was her brother.\n“Please stay,” said Clara.\n“I cannot,” said James.\nShe lowered her eyes.\n“Then promise you will come back,” said Clara.\n“I promise,” said James."
    static let trials: [Trial] = [
        .init(id: "english-tender-8", language: "en", voice: "alba", steps: 8, characters: false, text: tender),
        .init(id: "english-long-8", language: "en", voice: "george", steps: 8, characters: false, text: Array(repeating: "The path curved around the hill, where the old house waited beneath the trees. Clara paused at the gate. She could hear a piano through the open window, and for a moment she forgot how far she had traveled. Every room held a story, every familiar sound a memory she had thought was lost. She lifted the latch slowly and stepped into the garden. The afternoon light rested on the roses. Somewhere beyond the wall, a child was laughing.", count: 3).joined(separator: "\n\n")),
        .init(id: "english-dialogue-8", language: "en", voice: "alba", steps: 8, characters: true, text: dialogue),
        .init(id: "spanish-8", language: "es", voice: "lola", steps: 8, characters: false, text: "Se sentó junto a la ventana y abrió el libro con cuidado. Afuera, la lluvia había dejado de caer. No había ninguna prisa; aquella tarde les pertenecía. Recordó la voz de su abuela, suave y tranquila, contando historias mientras la casa se llenaba del aroma del café. Por primera vez en muchos años, sintió que estaba en casa."),
        .init(id: "english-tender-4", language: "en", voice: "alba", steps: 4, characters: false, text: tender),
        .init(id: "english-assigned-dialogue-8", language: "en", voice: "alba", steps: 8, characters: true, text: dialogue)
    ]
    @concurrent static func run(progress: @MainActor @Sendable (String) -> Void) async throws {
        let root = Bundle.main.bundleURL.appendingPathComponent("Assets")
        let assignedOnly = ProcessInfo.processInfo.arguments.contains("--assigned-only")
        let output = URL.documentsDirectory.appendingPathComponent(assignedOnly ? "AssignedResults" : "Results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = NarrationRenderer(compactDirectory: root, harmonicSource: nil)
        let pipeline = NarrationPipeline()
        var rows: [Measurement] = []
        func save(completed: Bool, error: String? = nil) throws {
            let report = Report(sdkCommit: "max-background-beta5-candidate", os: ProcessInfo.processInfo.operatingSystemVersionString,
                                physicalMemory: ProcessInfo.processInfo.physicalMemory, completed: completed, error: error, measurements: rows)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        }
        do {
            try await renderer.load(.pocket, directory: root, executionContext: .foreground)
            for trial in trials where !assignedOnly || trial.id.contains("assigned") {
                try Task.checkCancellation()
                var plan = try await pipeline.plan(trial.text, model: .pocket, bookID: "device-test", chapterID: trial.id,
                    narratorVoiceID: "pocket-\(trial.voice)-\(trial.language)-v1", language: trial.language,
                    characterVoices: trial.characters, pocketSampling: .init(temperature: 0.3, samplerSteps: trial.steps))
                if trial.id.contains("assigned"), var cast = plan.cast {
                    for character in cast.characters {
                        try cast.setVoice(character.name == "Clara" ? "pocket-anna-en-v1" : "pocket-george-en-v1", for: character.id)
                    }
                    plan = try await pipeline.plan(trial.text, model: .pocket, bookID: "device-test", chapterID: trial.id,
                        narratorVoiceID: "pocket-alba-en-v1", language: "en", cast: cast, characterVoices: true,
                        pocketSampling: .init(temperature: 0.3, samplerSteps: 8))
                    guard Set(plan.units.map(\.voiceID)).count == 3 else { throw NarrationRenderer.RenderError.unavailable("Assigned three-voice cast was not carried into the plan") }
                }
                var combined: [Float] = []
                for (index, unit) in plan.units.enumerated() {
                    try Task.checkCancellation()
                    await progress("\(trial.id): passage \(index + 1) of \(plan.units.count)")
                    let started = Date()
                    let samples = try await renderer.render(unit)
                    let elapsed = Date().timeIntervalSince(started)
                    guard samples.count > 2_400, samples.allSatisfy(\.isFinite) else { throw NarrationRenderer.RenderError.invalidAudio }
                    rows.append(.init(trial: trial.id, unit: index, text: unit.text, voice: unit.voiceID, steps: trial.steps,
                        renderSeconds: elapsed, audioSeconds: Double(samples.count) / 24_000,
                        peak: samples.lazy.map { abs($0) }.max() ?? 0, footprintBytes: footprint(),
                        thermalState: ProcessInfo.processInfo.thermalState.rawValue, cacheIdentity: NarrationModel.pocket.renderIdentity(for: unit)))
                    combined += samples
                    try save(completed: false)
                    logger.notice("MAX_UNIT \(trial.id, privacy: .public) \(index) render=\(elapsed) audio=\(Double(samples.count) / 24_000)")
                }
                try writeWave(combined, to: output.appendingPathComponent("\(trial.id).wav"))
            }
            await renderer.unload()
            try save(completed: true)
            logger.notice("MAX_DEVICE_COMPLETE")
        } catch {
            await renderer.unload()
            try? save(completed: false, error: String(describing: error))
            logger.error("MAX_DEVICE_FAILED \(String(describing: error), privacy: .public)")
            throw error
        }
    }
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
    static func writeWave(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw NarrationRenderer.RenderError.invalidAudio }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }
}
