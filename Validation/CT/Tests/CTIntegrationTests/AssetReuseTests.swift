import Foundation
import CryptoKit
import Testing
import LibroxTTS

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
    #expect(copied == ["same.bin"])
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
