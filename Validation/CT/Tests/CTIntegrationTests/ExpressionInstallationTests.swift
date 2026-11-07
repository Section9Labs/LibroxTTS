import Foundation
import Testing
import LibroxTTS
import LibroxCTNative

@Test func expressionGenerationKeepsOldInstallationsAndPinsEveryAddedFile() throws {
    let id = CTApprovedExpression.installationIdentity
    let manifest = try NarrationAssets.manifest(.plus, repositoryID: id)
    let base = try CTAssets.manifest()
    let combined = try CTAssets.manifest(identity: id)
    #expect(combined.identity == id)
    #expect(combined.files.count == base.files.count + 8)
    #expect(manifest.files.count == combined.files.count)
    #expect(NarrationAssets.repositoryID(.plus) == CTAssets.identity) // Candidate not activated publicly yet.
    #expect(NarrationAssets.compatibleRepositoryIDs(.plus).contains(id))
    #expect(NarrationAssets.compatibleRepositoryIDs(.plus).contains(CTAssets.releasedIdentity))
    #expect(NarrationAssets.supportedNativeStyles(repositoryID: id) == CTAssets.styles)
    #expect(!NarrationAssets.isDownloadPublished(.plus, repositoryID: id))
    #expect(!NarrationAssets.isDownloadPublished(.plus, repositoryID: "unknown-installation"))
    let old = Set(base.files.map { $0.sha256 + ":" + String($0.bytes) })
    let missing = manifest.files.filter { !old.contains($0.sha256 + ":" + String($0.size)) }
    #expect(missing.count == 6)
    #expect(missing.filter { $0.path.hasSuffix("weight.bin") }.isEmpty)
    for file in manifest.files {
        let pin = try #require(combined.files.first { $0.path == file.path })
        #expect(file.size == pin.bytes && file.sha256 == pin.sha256)
        let tag = old.contains(file.sha256 + ":" + String(file.size)) ? CTAssets.releaseTag : CTApprovedExpression.releaseTag
        #expect(manifest.url(for: file).path.contains("/releases/download/" + tag + "/"))
    }
    #expect(try NarrationAssets.estimatedDownloadSize(.plus, reusing: CTAssets.identity, targetRepositoryID: id)
        == missing.reduce(0) { $0 + $1.size })
    #expect(missing.reduce(0) { $0 + $1.size } < 400_000)
    #expect(NarrationAssets.preparationIdentity(.plus, repositoryID: id).contains(CTApprovedExpression.identity))
    #expect(NarrationAssets.preparationIdentity(.plus, repositoryID: id)
        != NarrationAssets.preparationIdentity(.plus, repositoryID: CTAssets.identity))
    #expect(CTAttribution.modifications.contains("Optional approved Round 07"))
}

@Test func expressionPlanningFollowsTheGenerationPinnedInstallation() async throws {
    let source = "Mara checked the drawer. \"It is with me,\" Mara said softly. The window broke."
    let pipeline = NarrationPipeline()
    let old = try await pipeline.plan(source, model: .plus, bookID: "pin-test", chapterID: "1",
        narratorVoiceID: "plus-f1-en-v1", language: "en", characterVoices: true, repositoryID: CTAssets.identity)
    let current = try await pipeline.plan(source, model: .plus, bookID: "pin-test", chapterID: "1",
        narratorVoiceID: "plus-f1-en-v1", language: "en", cast: old.cast,
        characterVoices: true, repositoryID: CTApprovedExpression.installationIdentity)
    #expect(old.units.allSatisfy { $0.nativeExpression == nil })
    #expect(current.units.contains { $0.nativeExpression != nil })
    #expect(current.units.map(\.voiceID) == old.units.map(\.voiceID))
    #expect(current.units.map(\.range) == old.units.map(\.range))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIBROX_EXPRESSION_INSTALL_ASSETS"] != nil))
func expressionInstallationVerifiesAndPreparesTheStagedGeneration() throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIBROX_EXPRESSION_INSTALL_ASSETS"]))
    let id = CTApprovedExpression.installationIdentity
    let manifest = try NarrationAssets.manifest(.plus, repositoryID: id)
    try NarrationAssets.validate(root, manifest: manifest)
    try NarrationAssets.prepare(root, model: .plus, repositoryID: id)
    #expect(NarrationAssets.isPrepared(root, model: .plus, repositoryID: id))
    let staged = root.deletingLastPathComponent().appendingPathComponent("public-release/download-manifest.json")
    let publicManifest = try JSONDecoder().decode(AssetManifest.self, from: Data(contentsOf: staged))
    #expect(publicManifest.revision == manifest.revision)
    #expect(publicManifest.files.map(\.path) == manifest.files.map(\.path))
    #expect(publicManifest.files.map(\.sha256) == manifest.files.map(\.sha256))
    #expect(publicManifest.files.map(\.size) == manifest.files.map(\.size))
    #expect(publicManifest.files.map(\.sourceURL) == manifest.files.map(\.sourceURL))
}
