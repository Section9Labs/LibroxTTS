import Foundation
import CryptoKit
import Testing
import LibroxTTS
import LibroxCTNative

@Test func modelUpdateReusesOnlyCurrentHashesAndPreservesOldInstallation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("installed"), staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let good = Data([1, 2, 3, 4]), stale = Data([5, 6, 7, 8])
    for name in ["same.bin", "changed.bin"] { try good.write(to: installed.appendingPathComponent(name)) }
    try stale.write(to: staging.appendingPathComponent("same.bin"))
    func pin(_ path: String, _ data: Data) -> [String: Any] {
        ["path": path, "size": data.count,
         "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    let files = [pin("same.bin", good), pin("changed.bin", stale), pin("missing.bin", good)]
    let json: [String: Any] = ["repository": "test", "revision": "new", "files": files, "installedFiles": files]
    let manifest = try JSONDecoder().decode(AssetManifest.self, from: JSONSerialization.data(withJSONObject: json))
    let copied = try NarrationAssets.reuseVerifiedFiles(manifest: manifest, from: [installed], into: staging)
    #expect(copied == ["same.bin", "missing.bin"])
    #expect(try Data(contentsOf: staging.appendingPathComponent("missing.bin")) == good)
    #expect(try Data(contentsOf: staging.appendingPathComponent("same.bin")) == good)
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("changed.bin").path))
    #expect(try Data(contentsOf: installed.appendingPathComponent("same.bin")) == good)
    #expect(try Data(contentsOf: installed.appendingPathComponent("changed.bin")) == good)
    #expect(throws: (any Error).self) {
        try NarrationAssets.reuseVerifiedFiles(manifest: manifest, from: [installed], into: installed)
    }
    #expect(throws: (any Error).self) {
        try NarrationAssets.reuseVerifiedFiles(manifest: manifest, from: [installed], into: installed.appendingPathComponent("nested"))
    }
}

@Test func modelUpdateAliasesRequireExactContentAndSize() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let installed = root.appendingPathComponent("installed"), staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let good = Data([1, 2, 3, 4]), corrupt = Data([1, 2, 3, 5])
    let digest = SHA256.hash(data: good).map { String(format: "%02x", $0) }.joined()
    let files: [[String: Any]] = ["original.bin", "expression/weight.bin"].map {
        ["path": $0, "size": good.count, "sha256": digest]
    }
    let json: [String: Any] = ["repository": "test", "revision": "new", "files": files, "installedFiles": files]
    let manifest = try JSONDecoder().decode(AssetManifest.self, from: JSONSerialization.data(withJSONObject: json))
    let source = installed.appendingPathComponent("original.bin")
    for bad in [corrupt, good + Data([0])] {
        try bad.write(to: source)
        #expect(try NarrationAssets.reuseVerifiedFiles(manifest: manifest, from: [installed], into: staging).isEmpty)
    }
    try good.write(to: source)
    #expect(try NarrationAssets.reuseVerifiedFiles(manifest: manifest, from: [installed], into: staging)
        == ["original.bin", "expression/weight.bin"])
    try Data([9, 9, 9, 9]).write(to: staging.appendingPathComponent("expression/weight.bin"))
    #expect(try Data(contentsOf: source) == good) // A private copy, never a writable shared inode.
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LIBROX_EXPRESSION_REUSE_ASSETS"] != nil))
func approvedExpressionReusesInstalledDKWeightsAtNewPaths() throws {
    let environment = ProcessInfo.processInfo.environment
    let installed = URL(fileURLWithPath: try #require(environment["LIBROX_EXPRESSION_REUSE_ASSETS"]))
    let graphs = URL(fileURLWithPath: try #require(environment["LIBROX_EXPRESSION_REUSE_GRAPHS"]))
    let base = try NarrationAssets.manifest(.plus, repositoryID: CTAssets.identity)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
    let graphManifest = try #require(JSONSerialization.jsonObject(with:
        Data(contentsOf: graphs.appendingPathComponent("manifest.json"))) as? [String: Any])
    let graphFiles = try #require(graphManifest["files"] as? [[String: Any]])
    let additional = try graphFiles.map { file -> [String: Any] in
        ["path": "expression/" + (try #require(file["path"] as? String)),
         "size": try #require(file["bytes"] as? Int), "sha256": try #require(file["sha256"] as? String)]
    }
    let files = try #require(json["files"] as? [[String: Any]]) + additional
    json["files"] = files; json["installedFiles"] = files
    let manifest = try JSONDecoder().decode(AssetManifest.self, from: JSONSerialization.data(withJSONObject: json))
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: staging) }
    let reused = try NarrationAssets.reuseVerifiedFiles(manifest: manifest, from: [installed], into: staging)
    #expect(reused.count == base.files.count + 2)
    #expect(reused.contains("expression/context_queries.mlpackage/Data/com.apple.CoreML/weights/weight.bin"))
    #expect(reused.contains("expression/spoken_context.mlpackage/Data/com.apple.CoreML/weights/weight.bin"))
    #expect(manifest.files.filter { !reused.contains($0.path) }.reduce(Int64(0)) { $0 + $1.size } == 378_565)
    // Validation reads the original model again; reuse has not moved or changed it.
    try NarrationAssets.validate(installed, manifest: base)
}
