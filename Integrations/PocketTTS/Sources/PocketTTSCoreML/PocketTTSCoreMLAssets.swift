import CoreML
import CryptoKit
import Foundation
import KokoroCatalog

/// Install into a private staging directory, then let the host atomically adopt
/// it. Never call preparation concurrently with rendering from that directory.
public enum PocketTTSCoreMLAssets {
    private struct File: Codable {
        let path: String
        let size: Int64
        let sha256: String
    }
    private struct Receipt: Codable {
        let identity: String
        let sourceDigest: String
        let operatingSystem: String
        let files: [File]
    }
    private static func digest(_ url: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func sourceDigest(_ language: String) throws -> String {
        let files = try PocketTTSCoreMLCatalog.manifest(language: language).installedFiles
        let content = files.map { "\($0.path):\($0.size):\($0.sha256)" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func modelDirectory(in directory: URL, language: String) -> URL {
        directory.appendingPathComponent(language).appendingPathComponent("coreml")
    }
    private static func receipt(in directory: URL, language: String) throws -> (Receipt, URL) {
        let root = modelDirectory(in: directory, language: language).appendingPathComponent("compiled")
        let value = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: root.appendingPathComponent("receipt.json")))
        guard value.identity == PocketTTSCoreMLCatalog.identity,
              value.sourceDigest == (try sourceDigest(language)),
              value.operatingSystem == ProcessInfo.processInfo.operatingSystemVersionString,
              !value.files.isEmpty,
              PocketTTSCoreMLCatalog.stages.allSatisfy({ stage in value.files.contains { $0.path.hasPrefix(stage + ".mlmodelc/") } }),
              value.files.allSatisfy({ !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (value, root)
    }
    public static func isPrepared(in directory: URL, language: String) -> Bool {
        guard let (receipt, root) = try? receipt(in: directory, language: language) else { return false }
        return receipt.files.allSatisfy { file in
            (try? root.appendingPathComponent(file.path).resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size)
        }
    }
    public static func validate(in directory: URL, language: String) throws {
        try PocketTTSCatalog.validate(PocketTTSCoreMLCatalog.manifest(language: language), in: directory)
        let (receipt, root) = try receipt(in: directory, language: language)
        for file in receipt.files {
            guard try digest(root.appendingPathComponent(file.path)) == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
    // iOS enumerators may expand /var to /private/var. Compare canonical
    // components rather than dropping a character count from an aliased URL.
    static func relativePath(_ file: URL, in directory: URL) throws -> String {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard path.count > root.count, Array(path.prefix(root.count)) == root else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return path.dropFirst(root.count).joined(separator: "/")
    }
    public static func prepare(in directory: URL, language: String) throws {
        try PocketTTSCatalog.validate(PocketTTSCoreMLCatalog.manifest(language: language), in: directory)
        if isPrepared(in: directory, language: language), (try? validate(in: directory, language: language)) != nil { return }
        try Task.checkCancellation()
        let root = modelDirectory(in: directory, language: language)
        let fm = FileManager.default
        let staging = root.appendingPathComponent("compile-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for stage in PocketTTSCoreMLCatalog.stages {
            try Task.checkCancellation()
            let compiled = try MLModel.compileModel(at: root.appendingPathComponent(stage + ".mlpackage"))
            defer { try? fm.removeItem(at: compiled) }
            try fm.copyItem(at: compiled, to: staging.appendingPathComponent(stage + ".mlmodelc"))
        }
        guard let enumerator = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var files: [File] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                files.append(try File(path: relativePath(url, in: staging),
                                      size: Int64(values.fileSize ?? 0), sha256: digest(url)))
            }
        }
        let receipt = try Receipt(identity: PocketTTSCoreMLCatalog.identity, sourceDigest: sourceDigest(language),
                                  operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, files: files.sorted { $0.path < $1.path })
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        try Task.checkCancellation()
        let destination = root.appendingPathComponent("compiled")
        let backup = root.appendingPathComponent("previous-" + UUID().uuidString)
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            if hadPrevious { try? fm.moveItem(at: backup, to: destination) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: backup) }
    }
}
