// SPDX-License-Identifier: Apache-2.0 OR MIT
// Copyright (c) 2026 Section9Labs and contributors
import Foundation
import KokoroCatalog

public enum ModelAssets {
    /// Verifies the complete pinned asset set before an application marks it installed.
    public static func validate(in directory: URL) throws {
        let manifest = try AssetManifest.bundled()
        for file in manifest.installedFiles {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.path)
            guard try matches(url, file: file) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
    }

    /// Unpack the pinned archive using system zlib on iOS, Catalyst and macOS.
    public static func prepare(in directory: URL) throws {
        let manifest = try AssetManifest.bundled()
        if manifest.isPresent(in: directory) {
            try validate(in: directory)
            for file in manifest.files { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.path)) }
            try configureForPlayback(directory)
            return
        }
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.path)
            guard try matches(url, file: file) else { throw CocoaError(.fileReadCorruptFile) }
            try ModelArchive.extract(url, into: directory, manifest: manifest)
        }
        try validate(in: directory)
        for file in manifest.files { try FileManager.default.removeItem(at: directory.appendingPathComponent(file.path)) }
        try configureForPlayback(directory)
    }

    /// Convenience downloader for sample apps and foreground setup. Applications needing
    /// process-surviving downloads can use AssetManifest with their own background URLSession.
    public static func download(to directory: URL,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let manifest = try AssetManifest.bundled()
        if manifest.isPresent(in: directory) {
            try validate(in: directory)
            try configureForPlayback(directory)
            progress?(1)
            return
        }
        try await VerifiedAssetTransfer().run(manifest, to: directory,
            matches: { try matches($0, file: $1) },
            invalid: { _ in CocoaError(.fileReadCorruptFile) }, progress: progress)
        try prepare(in: directory)
    }

    // Hash large model archives without making the entire download resident.
    private static func matches(_ url: URL, file: AssetManifest.File) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.size] as? Int64 == file.size else { return false }
        return try VerifiedAssetFile.matchesDigest(url, sha256: file.sha256)
    }

    private static func configureForPlayback(_ directory: URL) throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // Public model assets must remain readable when the screen locks.
        // Keep data protection across reboot until the device is first unlocked.
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try fm.setAttributes(attributes, ofItemAtPath: directory.path)
        if let entries = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in entries { try fm.setAttributes(attributes, ofItemAtPath: url.path) }
        }
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory
        try root.setResourceValues(values)
    }
}
