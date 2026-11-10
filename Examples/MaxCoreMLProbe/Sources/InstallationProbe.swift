import Foundation
import Darwin
import CryptoKit
import LibroxTTS
import PocketTTSCoreML
import KokoroCatalog

/// Exercises the public SDK path with a bundle containing no MLX checkpoint.
enum InstallationProbe {
    static func run(bundle: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("INSTALL copy")
        let installation = output.appendingPathComponent("pack-" + UUID().uuidString)
        try FileManager.default.copyItem(at: bundle.appendingPathComponent("install"), to: installation)
        guard !FileManager.default.fileExists(atPath: installation.appendingPathComponent("en/model.safetensors").path),
              PocketTTSBackend.platform == .coreML else { throw CocoaError(.fileReadCorruptFile) }
        print("INSTALL validated backend \(PocketTTSBackend.platform.rawValue)")
        let start = ProcessInfo.processInfo.systemUptime
        // Disk verification/compilation is synchronous and kept off the UI actor.
        try await Task.detached {
            print("INSTALL prepare")
            try NarrationAssets.preparePocketNarratorPreset(in: installation, language: "en")
        }.value
        print("INSTALL prepared")
        let prepareSeconds = ProcessInfo.processInfo.systemUptime - start
        guard NarrationAssets.isPrepared(installation, model: .pocket, language: "en") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("INSTALL ready")
        let renderer = NarrationRenderer(compactDirectory: URL(fileURLWithPath: "/unused"), harmonicSource: nil)
        let plan = try await NarrationPipeline().plan("She waited. Nobody came.", model: .pocket,
            bookID: "asset-split-probe", chapterID: "1", narratorVoiceID: "pocket-caro_davy-en-v1", language: "en",
            pocketSampling: .init(temperature: 0), pocketDelivery: .init(narratorStyle: .calm))
        guard let unit = plan.units.first else { throw CocoaError(.fileReadCorruptFile) }
        let direct = PocketTTSCoreMLEngine(directory: installation)
        print("INSTALL direct")
        let expected = try await direct.synthesize(unit.synthesisText, voiceID: unit.voiceID, temperature: 0,
            chunking: unit.pocketChunking ?? .init(), role: .narration,
            samplerSteps: unit.pocketSampling?.samplerSteps ?? 4, deliveryStyle: .calm).samples
        // Only one acoustic model is resident in the production path. Retain
        // the reference PCM, not a second model, while checking SDK routing.
        await direct.unload()
        print("INSTALL available after reference unload: \(os_proc_available_memory())")
        await renderer.setMaxResourceObserver { snapshot in
            if snapshot.phase == "operation-start" || snapshot.frameIndex == 0 {
                print("INSTALL resource \(snapshot.phase) available \(snapshot.availableBytes ?? 0) footprint \(snapshot.footprintBytes)")
            }
        }
        var modes: [[String: Any]] = []
        for (label, mode) in [("foreground", NarrationRenderer.ExecutionContext.foreground), ("background", .background), ("backgroundGPU", .backgroundGPU)] {
            print("INSTALL render \(label)")
            try await renderer.load(.pocket, directory: installation, executionContext: mode)
            let start = ProcessInfo.processInfo.systemUptime
            let actual = try await renderer.render(unit)
            let error = zip(actual, expected).map { abs($0 - $1) }.max() ?? .infinity
            print("INSTALL comparison \(label): actual \(actual.count), expected \(expected.count), max error \(error)")
            guard actual == expected else { throw CocoaError(.fileReadCorruptFile) }
            modes.append(["context": label, "sampleCount": actual.count, "matchesDirectCoreML": true,
                          "seconds": ProcessInfo.processInfo.systemUptime - start])
        }
        guard await renderer.loadedPocketLanguage == "en" else { throw CocoaError(.fileReadCorruptFile) }
        await renderer.setCPUBudget(fraction: nil)
        let unmetered = try await renderer.render(unit)
        guard unmetered == expected else { throw CocoaError(.fileReadCorruptFile) }
        let sentinel = installation.appendingPathComponent("es/other-language-sentinel")
        try FileManager.default.createDirectory(at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserve-other-language".utf8).write(to: sentinel)
        let freed = try await renderer.uninstallPocketLanguage("en", in: installation)
        guard freed > 0, await renderer.loadedPocketLanguage == nil,
              FileManager.default.fileExists(atPath: sentinel.path),
              !FileManager.default.fileExists(atPath: installation.appendingPathComponent("en").path) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        await renderer.unload(); await direct.unload()
        let report: [String: Any] = ["passed": true, "backend": PocketTTSBackend.platform.rawValue,
            "repositoryID": NarrationAssets.repositoryID(.pocket), "runtimeIdentity": NarrationModel.pocket.deliveryIdentity,
            "originalWeightsPresent": false, "prepareSeconds": prepareSeconds, "routes": modes,
            "backgroundCPUBudget": 0.5, "explicitUnmeteredOutputMatches": true,
            "loadedLanguageUninstallPassed": true, "otherLanguagePreserved": true, "uninstalledBytes": freed,
            "note": "Execution-context routing test; application remains foreground during this test."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("installation-report.json"), options: .atomic)
    }
}
