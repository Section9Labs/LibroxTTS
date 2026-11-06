import SwiftUI
import UIKit
import LibroxCTNative

@main struct CTDeviceProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}
struct ProbeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = "Ready"
    @State private var running = false
    var body: some View {
        VStack(spacing: 24) {
            Text("CT Core ML 2").font(.title)
            Text(status).textSelection(.enabled)
            Button("Run English and Spanish fixtures") { run() }.disabled(running)
            Button("Measure repeated rendering") { run(benchmark: true) }.disabled(running)
            Button("Test varied passages and backend switches") { run(passages: true) }.disabled(running)
        }.padding().task {
            if ProcessInfo.processInfo.arguments.contains("--run-passages") { run(passages: true) }
            else if ProcessInfo.processInfo.arguments.contains("--run-benchmark") { run(benchmark: true) }
            else if ProcessInfo.processInfo.arguments.contains("--run-fixtures") { run() }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
    }
    private func run(benchmark: Bool = false, passages: Bool = false) {
        guard !running else { return }
        running = true; status = benchmark ? "Measuring repeated renders…" : "Rendering native fixtures…"
        Task {
            do {
                guard let assets = Bundle.main.url(forResource: "CTCoreMLV2GPUAssets", withExtension: nil),
                      let fixtures = Bundle.main.url(forResource: "Fixtures", withExtension: nil) else {
                    throw CTError.invalidAssets("test bundle")
                }
                let output = URL.documentsDirectory.appendingPathComponent((passages ? "passages-" : benchmark ? "benchmark-" : "parity-") + UUID().uuidString)
                let backend = CTEngine.Backend(rawValue: ProcessInfo.processInfo.environment["CT_BACKEND"] ?? "coreMLGPUHeavy") ?? .coreMLGPUHeavy
                if passages {
                    try await DeviceValidation.passages(assets: assets, output: output, backend: backend)
                } else if benchmark {
                    try await DeviceValidation.benchmark(assets: assets, fixtures: fixtures, output: output, backend: backend)
                } else {
                    try await DeviceValidation.run(assets: assets, fixtures: fixtures, output: output, backend: backend)
                }
                status = "Finished. Results saved in Files: \(output.lastPathComponent)."
                print("\(passages ? "CT_PASSAGES_COMPLETE" : benchmark ? "CT_BENCHMARK_COMPLETE" : "CT_VALIDATION_COMPLETE") \(output.lastPathComponent)")
            } catch {
                status = "Failed: \(error.localizedDescription)"
                print("CT_VALIDATION_FAILED \(error)")
            }
            running = false
        }
    }
}
