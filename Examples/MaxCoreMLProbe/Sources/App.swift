import SwiftUI
import PocketBackendBenchmark
import AVFoundation

@main struct MaxCoreMLProbe: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}
@MainActor enum Playback {
    static var player: AVQueuePlayer?
    static func enqueue(_ url: URL) { player?.insert(AVPlayerItem(url: url), after: nil) }
}
struct ProbeView: View {
    @Environment(\.scenePhase) private var phase
    @State private var status = "Ready"
    @State private var job: Task<Void, Never>?
    @State private var player: AVQueuePlayer?
    var body: some View {
        VStack(spacing: 24) {
            Text("Max Core ML benchmark").font(.title)
            Text(status).textSelection(.enabled)
            Button("Run") { run() }.disabled(job != nil)
        }.padding().task { if CommandLine.arguments.contains("--run") { run() } }
        .onChange(of: phase) { _, phase in
            if phase != .active && !CommandLine.arguments.contains("--background") { job?.cancel() }
            UIApplication.shared.isIdleTimerDisabled = phase == .active && job != nil
        }
    }
    private func run() {
        guard job == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        job = Task {
            let args = CommandLine.arguments
            let name = args.firstIndex(of: "--request").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "coreml"
            let base = Bundle.main.resourceURL!.appendingPathComponent("Assets")
            let output = URL.documentsDirectory.appendingPathComponent(name)
            do {
                let request = try JSONDecoder().decode(PocketBackendBenchmark.Request.self,
                    from: Data(contentsOf: base.appendingPathComponent("requests/\(name).json")))
                if args.contains("--background") {
                    guard ["coreml-cpu", "coreml-ane", "mlx-cpu"].contains(request.backend) else {
                        throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Background test requires explicit GPU-free placement"])
                    }
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                    let buffer = base.appendingPathComponent("prebuffer.wav")
                    let queue = AVQueuePlayer(items: (0..<8).map { _ in AVPlayerItem(url: buffer) })
                    player = queue; queue.play()
                    Playback.player = queue
                    try saveBackground("waitingForBackground", output: output)
                    status = "Playing narration. Waiting for background…"
                    let deadline = Date().addingTimeInterval(120)
                    while UIApplication.shared.applicationState != .background {
                        try Task.checkCancellation()
                        guard Date() < deadline else { throw NSError(domain: "Probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Background transition timed out"]) }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    try await Task.sleep(for: .seconds(3))
                    try saveBackground("generatingInBackground", output: output)
                }
                status = "Running \(request.backend)"
                let isBackground = args.contains("--background")
                _ = try await PocketBackendBenchmark.run(request, assets: base.appendingPathComponent("original"),
                    models: base.appendingPathComponent("coreml"), output: output, onTrial: { url in
                        if isBackground { await Playback.enqueue(url) }
                    })
                if args.contains("--background") { try saveBackground("completedInBackground", output: output) }
                status = "Completed: \(name)"
                print(status)
            } catch {
                status = "Stopped: \(error)"
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try? Data(status.utf8).write(to: output.appendingPathComponent("error.txt"))
                print(status)
            }
            UIApplication.shared.isIdleTimerDisabled = false
            player?.pause(); player = nil
            Playback.player = nil
            if args.contains("--background") { try? AVAudioSession.sharedInstance().setActive(false) }
            job = nil
        }
    }
    private func saveBackground(_ stage: String, output: URL) throws {
        let row: [String: Any] = ["stage": stage, "applicationState": UIApplication.shared.applicationState.rawValue,
            "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
            "playbackRate": player?.rate ?? 0, "playbackSecondsInCurrentItem": player?.currentTime().seconds ?? 0,
            "remainingQueueItems": player?.items().count ?? 0, "timestamp": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted,.sortedKeys])
            .write(to: output.appendingPathComponent("\(stage).json"), options: .atomic)
        print(stage)
    }
}
