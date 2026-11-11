import CoreML
import CryptoKit
import Foundation

/// Source hashes plus OS/architecture identify reusable compiler output. The
/// asset bundle is verified before calling this cache. A process-safe lock and
/// atomic publication prevent partial compiler output from becoming visible.
enum CTCompiledModelCache {
    static func modelURL(for package: URL) throws -> URL {
        let name = package.lastPathComponent
        let files = try CTAssets.manifest().files.filter { $0.path.hasPrefix("coreml/" + name + "/") }
        guard !files.isEmpty else { throw CTError.invalidAssets(name) }
        return try modelURL(for: package,
            verifiedIdentity: files.sorted { $0.path < $1.path }.map { $0.path + ":" + $0.sha256 })
    }

    /// Internal only: callers must verify all source bytes against SDK-pinned hashes first.
    static func modelURL(for package: URL, verifiedIdentity: [String]) throws -> URL {
        guard !verifiedIdentity.isEmpty else { throw CTError.invalidAssets("compiler source identity") }
        let fm = FileManager.default
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let identity = (["ct-compiler-cache-v1", architecture, ProcessInfo.processInfo.operatingSystemVersionString]
            + verifiedIdentity).joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let root: URL
        if let override = ProcessInfo.processInfo.environment["CT_COMPILE_CACHE_ROOT"] {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("com.section9labs.LibroxTTS.CT/v2", isDirectory: true)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return try CTCompilerLock.withLock(root: root, key: key) {
            let destination = root.appendingPathComponent(key, isDirectory: true)
            let model = destination.appendingPathComponent("model.mlmodelc", isDirectory: true)
            let receipt = destination.appendingPathComponent("identity.txt")
            if (try? String(contentsOf: receipt, encoding: .utf8)) == identity,
               fm.fileExists(atPath: model.path) { return model }
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            let staging = root.appendingPathComponent(".compile-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let compiled = try MLModel.compileModel(at: package)
            defer { try? fm.removeItem(at: compiled) }
            // Compilation cannot be interrupted. Once it finishes, publish its
            // valid result even if speculation was cancelled while it ran. The
            // successor can reuse this work without loading two models at once.
            try fm.copyItem(at: compiled, to: staging.appendingPathComponent("model.mlmodelc"))
            try identity.write(to: staging.appendingPathComponent("identity.txt"), atomically: true, encoding: .utf8)
            #if os(iOS)
            if let entries = fm.enumerator(at: staging, includingPropertiesForKeys: nil) {
                for case let file as URL in entries {
                    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                }
            }
            #endif
            try fm.moveItem(at: staging, to: destination)
            try Task.checkCancellation()
            return model
        }
    }
}
