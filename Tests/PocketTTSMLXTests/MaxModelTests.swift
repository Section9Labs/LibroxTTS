import Foundation
import Testing
import LibroxTTS
import LibroxCTNative
import KokoroCatalog

@Test func maxPreservesSavedModelAndAssetIdentities() throws {
    #expect(NarrationModel.pocket.name == "Max")
    #expect(try JSONDecoder().decode(NarrationModel.self, from: Data("\"pocketTTSV1\"".utf8)) == .pocket)
    #expect(try JSONEncoder().encode(NarrationModel.pocket) == Data("\"pocketTTSV1\"".utf8))
    #expect(NarrationModel.plus.rawValue == "ctPlusV1")
    #expect(NarrationModel.plus.name == "Plus")
    let plusIndex = try #require(NarrationModel.allCases.firstIndex(of: .plus))
    let maxIndex = try #require(NarrationModel.allCases.firstIndex(of: .pocket))
    #expect(plusIndex < maxIndex)
    #expect(NarrationAssets.repositoryID(.pocket) == "pocket-tts-mlx-2026-11-07-v2")
    #expect(NarrationModel.pocket.requiresPlusAccess)
    #expect(!NarrationModel.pocket.requiresPreparation)
    #expect(NarrationModel.pocket.supportsBackgroundGeneration)
    #expect(NarrationModel.pocket.outputSampleRate == 24_000)
}

@Test(arguments: [
    NarrationModel.Device(appleSilicon: true, desktop: false, physicalMemory: 4_000_000_000, identifier: "iPhone12,1"),
    NarrationModel.Device(appleSilicon: true, desktop: false, physicalMemory: 3_000_000_000, identifier: "iPad11,6"),
    NarrationModel.Device(appleSilicon: true, desktop: false, physicalMemory: 8_000_000_000, identifier: "iPad16,3"),
    NarrationModel.Device(appleSilicon: true, desktop: true, physicalMemory: 8_000_000_000, identifier: "MacBookAir10,1"),
    NarrationModel.Device(appleSilicon: true, desktop: false, physicalMemory: 4_000_000_000, identifier: "future-device")
])
func maxAvailabilityDoesNotUseDesktopOrTestedDeviceAllowlist(device: NarrationModel.Device) {
    // Availability policy only: these descriptors are not physical-device tests.
    #expect(NarrationModel.pocket.unavailableReason(on: device) == nil)
    #expect(NarrationModel.available(on: device).contains(.pocket))
}

@Test func maxRetainsArchitectureRequirementAndExistingPlusPolicy() {
    let intel = NarrationModel.Device(appleSilicon: false, desktop: true, physicalMemory: 16_000_000_000, identifier: "Intel-Mac")
    #expect(NarrationModel.pocket.unavailableReason(on: intel) != nil)
    let unqualifiedPlus = NarrationModel.Device(appleSilicon: true, desktop: false, physicalMemory: 4_000_000_000, identifier: "iPhone12,1")
    #expect(NarrationModel.plus.unavailableReason(on: unqualifiedPlus) != nil)
}

@Test func maxNativeStyleLookupKeepsAllRetainedVoicesVisible() {
    let names = NarrationAssets.supportedNativeStyles(repositoryID: NarrationAssets.repositoryID(.pocket))
    #expect(names == PocketTTSCatalog.voiceNames)
    #expect(names.count == 23)
    #expect(Set(NarrationModel.pocket.nativeVoices.map(\.styleID)) == Set(names))
    #expect(NarrationAssets.supportedNativeStyles(repositoryID: CTAssets.releasedIdentity) == ["F1"])
    #expect(NarrationAssets.supportedNativeStyles(repositoryID: "unknown").isEmpty)
}

@Test func maxAutomaticCastUsesVerifiedVoiceMetadataAndPreservesManualChoice() async throws {
    let pipeline = NarrationPipeline()
    let text = "Clara was her sister. James was her brother.\n“Please stay,” said Clara.\n“I cannot,” said James."
    let plan = try await pipeline.plan(text, model: .pocket, bookID: "cast", chapterID: "one",
        narratorVoiceID: "pocket-alba-en-v1", language: "en", characterVoices: true)
    var cast = try #require(plan.cast)
    let clara = try #require(cast.characters.first { $0.name == "Clara" })
    let james = try #require(cast.characters.first { $0.name == "James" })
    #expect(clara.voiceID == "pocket-anna-en-v1")
    #expect(james.voiceID == "pocket-charles-en-v1")
    #expect(Set(plan.units.map(\.voiceID)).count == 3)
    try cast.setVoice("pocket-george-en-v1", for: clara.id)
    let expanded = try NarrationModel.pocket.expandingVoiceCatalog(in: cast)
    #expect(expanded.characterVoices[clara.id] == "pocket-george-en-v1")
    for language in PocketTTSCatalog.languages {
        #expect(PocketTTSCatalog.voice(id: "pocket-anna-\(language)-v1")?.gender == .female)
        #expect(PocketTTSCatalog.voice(id: "pocket-charles-\(language)-v1")?.gender == .male)
        #expect(PocketTTSCatalog.voice(id: "pocket-alba-\(language)-v1")?.gender == .unknown)
    }
}
