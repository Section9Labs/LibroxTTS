import Foundation
import Testing
import LibroxTTS
import LibroxCTNative

@Test func retainedInstallationHasItsOwnPinnedManifestAndVoiceCapabilities() throws {
    let released = try CTAssets.manifest(identity: CTAssets.releasedIdentity)
    #expect(released.identity == "librox-plus-ct-f1-coremlgpu-v2")
    #expect(released.files.count == 23)
    #expect(released.files.reduce(0) { $0 + $1.bytes } == 439_248_281)
    #expect(NarrationAssets.supportedNativeStyles(repositoryID: released.identity) == ["F1"])
    #expect(NarrationAssets.supportedNativeStyles(repositoryID: CTAssets.identity).count == 10)
    #expect(try NarrationAssets.manifest(.plus, repositoryID: released.identity).revision == CTAssets.releasedTag)
    #expect(throws: CTError.self) { try NarrationAssets.manifest(.compact, repositoryID: released.identity) }
    #expect(throws: CTError.self) { try CTAssets.manifest(identity: "untrusted-manifest") }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_LEGACY_ASSETS"] != nil))
func retainedRendererUsesPinnedF1AndRejectsUnavailableStylesWithoutDamagingPlayback() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CT_LEGACY_ASSETS"]))
    let engine = CTEngine(directory: directory, backend: .coreMLGPUHeavy, assetIdentity: CTAssets.releasedIdentity)
    try await engine.load()
    let original = try await engine.synthesize("The letter was waiting by the door.", language: "en", captureTrace: true, completeSentence: false)
    let noise = try #require(original.trace["initial_latent"])
    await #expect(throws: CTError.self) { try await engine.setVoice("dk-m1-v1") }
    await #expect(throws: CTError.self) { try await engine.setVoice("dk-f1-v1", blend: .init(secondaryVoiceID: "dk-f2-v1", weight: 0.2)) }
    let after = try await engine.synthesize("The letter was waiting by the door.", language: "en", initialNoise: noise, completeSentence: false)
    #expect(original.samples == after.samples)
    #expect(original.samples.allSatisfy { $0.isFinite })
    await engine.unload()
}
