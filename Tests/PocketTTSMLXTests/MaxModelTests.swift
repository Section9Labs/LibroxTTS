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
    #expect(NarrationModel.pocket.requiresPreparation)
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
