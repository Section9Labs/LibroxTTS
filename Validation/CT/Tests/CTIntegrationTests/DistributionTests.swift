import Foundation
import Testing
import KokoroNarration
import LibroxTTS
import LibroxCTNative

@Test func plusBetaPinsPublishedFilesAndRetainsModelLicense() throws {
    let manifest = try NarrationAssets.manifest(.plus)
    let native = try CTAssets.manifest()
    // The beta assets are public; every URL remains pinned to its immutable release.
    #expect(NarrationAssets.isDownloadPublished(.plus))
    #expect(native.identity == "librox-plus-dk-coreml-v2")
    #expect(manifest.revision == CTAssets.releaseTag)
    #expect(manifest.downloadSize > 400_000_000 && manifest.downloadSize < 500_000_000)
    #expect(manifest.files.count == native.files.count)
    #expect(Set(manifest.files.map(\.path)).count == manifest.files.count)
    for file in manifest.files {
        let pin = try #require(native.files.first { $0.path == file.path })
        #expect(file.size == pin.bytes && file.sha256 == pin.sha256)
        let url = manifest.url(for: file)
        #expect(url.scheme == "https" && url.host == "github.com")
        #expect(url.path.contains("/Section9Labs/LibroxTTS/releases/download/" + CTAssets.releaseTag + "/"))
        #expect(!url.path.contains("/latest/"))
    }
    #expect(manifest.files.contains { $0.path == "licenses/model-LICENSE" })
    #expect(manifest.files.contains { $0.path == "licenses/MODIFICATIONS.md" })
    #expect(manifest.files.contains { $0.path == "voice_styles/F1.json" })
    #expect(manifest.files.contains { $0.path == "voice_styles/M1.json" })
    for style in CTAssets.styles {
        #expect(manifest.files.contains { $0.path == "voice_styles/\(style).json" })
    }
    #expect(native.parameterCount == CTAssets.parameterCount)
    #expect(CTAttribution.modelLicense.contains("Attachment A"))
    #expect(CTAttribution.modifications.contains("modified derivative"))
    #expect(KokoroAttribution.text.contains(CTAttribution.modelLicense))
}

@Test func officialPlusKeepsDeviceEligibilityExplicit() {
    #expect(NarrationModel.plus.unavailableReason(on: .init(appleSilicon: true,
        desktop: false, physicalMemory: 12_263_407_616, identifier: "iPhone18,2")) == nil)
    #expect(NarrationModel.plus.unavailableReason(on: .init(appleSilicon: true,
        desktop: false, physicalMemory: 7_817_789_440, identifier: "iPad16,3")) == nil)
    #expect(NarrationModel.plus.unavailableReason(on: .init(appleSilicon: true,
        desktop: false, physicalMemory: 4_000_000_000, identifier: "untested")) != nil)
}
