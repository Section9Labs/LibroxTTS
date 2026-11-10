import XCTest
import Foundation
import KokoroCatalog
import KokoroNarration
import LibroxTTS
import PocketTTSCoreML

final class AssetRoutingTests: XCTestCase {
    func testDevicePolicyAndCacheIdentities() throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        XCTAssertEqual(PocketTTSBackend.platform, .coreML)
        XCTAssertEqual(NarrationAssets.previousRepositoryIDs(.pocket), [PocketTTSCatalog.identity])
        #else
        XCTAssertEqual(PocketTTSBackend.platform, .mlx)
        #endif
        XCTAssertEqual(NarrationAssets.repositoryID(.pocket), PocketTTSBackend.platform.repositoryID)
        XCTAssertEqual(NarrationModel.pocket.deliveryIdentity, PocketTTSBackend.platform.runtimeIdentity)
        XCTAssertNotEqual(PocketTTSBackend.mlx.runtimeIdentity, PocketTTSBackend.coreML.runtimeIdentity)
        let other = PocketTTSBackend.platform == .mlx ? PocketTTSBackend.coreML : .mlx
        XCTAssertThrowsError(try NarrationAssets.manifest(.pocket, repositoryID: other.repositoryID))
        XCTAssertEqual(PocketTTSSamplingOptions().samplerSteps, 4)
        XCTAssertEqual(PocketTTSSamplingOptions().temperature, 0.3)
        let preset = try PocketTTSNarratorPreset.defaultNarrator(language: "en")
        XCTAssertEqual(preset.voiceID, "pocket-caro_davy-en-v1")
        XCTAssertEqual(preset.delivery.narratorStyle, .calm)
    }

    func testEveryLanguageDownloadsOneBackendAndUnchangedSharedAssets() throws {
        for language in PocketTTSCatalog.languages {
            let mlx = try PocketTTSBackend.mlx.manifest(language: language)
            let core = try PocketTTSBackend.coreML.manifest(language: language)
            XCTAssertTrue(mlx.files.contains { $0.path == language + "/model.safetensors" })
            XCTAssertFalse(mlx.files.contains { $0.path.contains(".mlpackage/") })
            XCTAssertFalse(core.files.contains { $0.path.hasSuffix("/model.safetensors") })
            XCTAssertFalse(core.files.contains { $0.path.contains(".mlmodelc/") })
            XCTAssertEqual(Set(core.files.map(\.path)).count, core.files.count)
            for file in mlx.files where !file.path.hasSuffix("/model.safetensors") {
                let shared = try XCTUnwrap(core.files.first { $0.path == file.path })
                XCTAssertEqual(shared.sha256, file.sha256)
                XCTAssertEqual(shared.sourceURL, file.sourceURL)
            }
            for stage in PocketTTSCoreMLCatalog.stages {
                XCTAssertTrue(core.files.contains { $0.path.contains("/\(stage).mlpackage/") })
            }
            let preset = try PocketTTSDeliveryCatalog.narratorManifest(voiceID: "pocket-caro_davy-\(language)-v1", style: .calm, backend: .coreML)
            XCTAssertFalse(preset.files.contains { $0.path.hasSuffix("/model.safetensors") })
            XCTAssertTrue(preset.files.contains { $0.path.hasSuffix("/caro_davy__calm.safetensors") })
            let original = try PocketTTSDeliveryCatalog.manifest(voiceID: "pocket-caro_davy-\(language)-v1", style: .original, backend: .coreML)
            XCTAssertEqual(original.files.map(\.path), core.files.map(\.path))
        }
    }

    func testVerifiedMigrationReusesSharedFilesWithoutMovingOldWeights() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), staging = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old.appendingPathComponent("en"), withIntermediateDirectories: true)
        // Real, small config from the verified original installation.
        guard let path = ProcessInfo.processInfo.environment["POCKET_ASSETS"] else { throw XCTSkip("Verified assets required") }
        let core = try PocketTTSCoreMLCatalog.manifest(language: "en")
        let config = try XCTUnwrap(core.files.first { $0.path == "en/config.json" })
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path).appendingPathComponent(config.path), to: old.appendingPathComponent(config.path))
        let weight = old.appendingPathComponent("en/model.safetensors")
        try Data("old-model-sentinel".utf8).write(to: weight)
        let copied = try NarrationAssets.reuseVerifiedFiles(manifest: core, from: [old], into: staging)
        XCTAssertEqual(copied, [config.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: weight.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("en/model.safetensors").path))
        try Data("bad".utf8).write(to: old.appendingPathComponent(config.path))
        let empty = root.appendingPathComponent("empty")
        XCTAssertTrue(try NarrationAssets.reuseVerifiedFiles(manifest: core, from: [old], into: empty).isEmpty)
    }

    func testRealCoreMLOnlyPackMatchesBenchmarkLayout() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pack = env["POCKET_COREML_PACK"], let assets = env["POCKET_ASSETS"], let models = env["POCKET_COREML"] else {
            throw XCTSkip("Real Core ML-only pack required")
        }
        let root = URL(fileURLWithPath: pack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("en/model.safetensors").path))
        try PocketTTSCoreMLAssets.prepare(in: root, language: "en")
        XCTAssertTrue(PocketTTSCoreMLAssets.isPrepared(in: root, language: "en"))
        let isolated = PocketTTSCoreMLEngine(directory: root)
        let reference = PocketTTSCoreMLEngine(directory: URL(fileURLWithPath: assets), modelsDirectory: URL(fileURLWithPath: models), placement: .cpu)
        for steps in [4, 8, 3] {
            await isolated.setRandomSeed(42); await reference.setRandomSeed(42)
            let a = try await isolated.synthesize("She waited. Nobody came.", voiceID: "pocket-caro_davy-en-v1", temperature: 0.3, chunking: .carefulReading, samplerSteps: steps, deliveryStyle: .calm)
            let b = try await reference.synthesize("She waited. Nobody came.", voiceID: "pocket-caro_davy-en-v1", temperature: 0.3, chunking: .carefulReading, samplerSteps: steps, deliveryStyle: .calm)
            XCTAssertEqual(a.samples, b.samples, "Changed output for sampler \(steps)")
        }
        await isolated.unload(); await reference.unload()
        // A damaged prepared graph must not be accepted as ready or playable.
        let receipt = root.appendingPathComponent("en/coreml/compiled/receipt.json")
        let saved = try Data(contentsOf: receipt)
        defer { try? saved.write(to: receipt) }
        try Data("invalid".utf8).write(to: receipt)
        XCTAssertFalse(PocketTTSCoreMLAssets.isPrepared(in: root, language: "en"))
        XCTAssertThrowsError(try PocketTTSCoreMLAssets.validate(in: root, language: "en"))
    }
}
