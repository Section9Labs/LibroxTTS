import Foundation
import SwiftUI
import UIKit
import LibroxChatterboxMLX

@main @MainActor
struct Q8ReplayProbeApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = ProbeState()
    init() { setenv("MLX_ENABLE_TF32", "0", 1) }
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 20) {
                Text("Q8 accuracy diagnostic").font(.title2.bold())
                Text(state.phase)
                Text("Public test inputs only. No recordings or narration.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Build " + ProbeState.buildLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(30)
            .task { if scenePhase == .active { state.start() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { state.start() }
                else { state.cancel(reason: "foregroundEnded") }
            }
        }
    }
}

@MainActor
private final class ProbeState: ObservableObject {
    @Published var phase = "Waiting for foreground"
    private var started = false
    private var work: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stopReason: String?
    private var runID: String?
    private let launchID = UUID().uuidString
    private var activeRunDirectory: URL?
    static var buildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(version) (\(build))"
    }
    private var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("q8-cache-replay-v01", isDirectory: true)
    }
    private var launchDirectory: URL { root.appendingPathComponent("launches/" + launchID, isDirectory: true) }
    private struct Request: Decodable {
        let runID: UUID
        let expiresAt: Double
        let sdkRevision: String
    }
    func start() {
        guard !started, UIApplication.shared.applicationState == .active else { return }
        started = true
        UIApplication.shared.isIdleTimerDisabled = true
        watchdog = Task {
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            cancel(reason: "boundedSessionTimeout")
        }
        work = Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                watchdog?.cancel(); watchdog = nil; work = nil
                ChatterboxMLXRenderer.trimUnusedMemory()
            }
            do {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("inputs"),
                                                        withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: launchDirectory, withIntermediateDirectories: true)
                phase = "Waiting for diagnostic files"
                try writeStatus("waiting")
                let requestURL = root.appendingPathComponent("request.json")
                while !FileManager.default.fileExists(atPath: requestURL.path) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
                // Retire even an invalid/expired request once, preserving its
                // bytes in this launch's owned evidence directory.
                let archivedRequest = launchDirectory.appendingPathComponent("received-request.json")
                try FileManager.default.moveItem(at: requestURL, to: archivedRequest)
                let requestData = try Data(contentsOf: archivedRequest)
                let request = try JSONDecoder().decode(Request.self, from: requestData)
                let expectedSDK = Bundle.main.object(forInfoDictionaryKey: "LibroxSDKRevision") as? String
                guard request.expiresAt > Date().timeIntervalSince1970,
                    request.expiresAt <= Date().timeIntervalSince1970 + 180,
                    request.sdkRevision == expectedSDK else { throw ProbeError.invalidRequest }
                runID = request.runID.uuidString
                let directory = root.appendingPathComponent("runs/" + request.runID.uuidString, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw ProbeError.alreadyConsumed }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                activeRunDirectory = directory
                try requestData.write(to: directory.appendingPathComponent("consumed-request.json"), options: .atomic)
                try Task.checkCancellation()
                guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
                phase = "Measuring three fixed-input cases"
                try writeStatus("running")
                ChatterboxMLXRenderer.configureBufferCache(maximumBytes: 64 * 1_024 * 1_024)
                let inputs = root.appendingPathComponent("inputs", isDirectory: true)
                let result = try await ChatterboxQ8FixedFixtureDiagnostic.run(.init(
                    weightsFile: inputs.appendingPathComponent("backbone-q8-g64-f16scales.safetensors"),
                    oracleFile: inputs.appendingPathComponent("q8-dense-cpu-reference-v01.safetensors"),
                    cpuPrefillCacheFile: inputs.appendingPathComponent("cpu-es-prefill-kv-v01.safetensors")))
                try Task.checkCancellation()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(result).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
                phase = "Complete. You can return to Librox."
                try writeStatus("complete")
                print("Q8_REPLAY_COMPLETE \(request.runID.uuidString)")
            } catch {
                let ns = error as NSError
                let status = error is CancellationError ? "cancelled" : "failed"
                phase = error is CancellationError ? "Stopped" : "Diagnostic stopped"
                try? writeStatus(status, error: ["domain": ns.domain, "code": ns.code,
                                                "reason": stopReason ?? String(describing: error)])
                print("Q8_REPLAY_STOPPED \(status)")
            }
        }
    }
    func cancel(reason: String) {
        guard work != nil else { return }
        stopReason = reason
        phase = "Stopping"
        work?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
    }
    private func writeStatus(_ status: String, error: [String: Any]? = nil) throws {
        var value: [String: Any] = ["status": status, "at": Date().timeIntervalSince1970,
            "build": Self.buildLabel, "sdkRevision": Bundle.main.object(forInfoDictionaryKey: "LibroxSDKRevision") as? String ?? "unknown",
            "diagnosticOnly": true, "runID": runID ?? "pending", "launchID": launchID, "idleHoldMaximumSeconds": 90]
        if let error { value["error"] = error }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: launchDirectory.appendingPathComponent("status.json"), options: .atomic)
        if let activeRunDirectory { try data.write(to: activeRunDirectory.appendingPathComponent("status.json"), options: .atomic) }
        try data.write(to: root.appendingPathComponent("latest-status.json"), options: .atomic)
    }
    private enum ProbeError: Error { case invalidRequest, alreadyConsumed }
}
