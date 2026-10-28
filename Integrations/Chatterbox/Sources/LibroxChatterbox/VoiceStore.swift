import Foundation
import CryptoKit
import ChatterboxCoreML

public enum ChatterboxVoiceOrigin: String, Codable, Sendable { case ownRecording, authorizedReference }

public struct ChatterboxSavedVoice: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let language: String
    public let createdAt: Date
    public let modelFamily: String
    public let schemaVersion: Int
    public let conditioningSHA256: String
    public let conditioningBytes: Int
    public let origin: ChatterboxVoiceOrigin
    public let referenceSHA256: String
    public let referenceSeconds: Double
    public let listeningAccepted: Bool
}

/// Private, persistent reusable voices. Model weights and PCM caches live elsewhere.
/// The host supplies its per-account Application Support directory.
public actor ChatterboxVoiceStore {
    public enum StoreError: Error, Equatable { case invalidName, invalidReference, unsafePath, damagedVoice, incompatibleModel }
    public static let modelFamily = "chatterbox-multilingual-v3"
    private let directory: URL

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw StoreError.unsafePath }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try Self.requireReal(directory, isDirectory: true)
        self.directory = directory
    }

    public func save(name: String, language: String, conditioningFile: URL,
                     origin: ChatterboxVoiceOrigin, referenceSHA256: String,
                     referenceSeconds: Double, listeningAccepted: Bool) throws -> ChatterboxSavedVoice {
        try Task.checkCancellation()
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw StoreError.invalidName }
        guard ChatterboxRequest.languages.contains(language), Self.validHash(referenceSHA256),
              referenceSeconds.isFinite, (1...20).contains(referenceSeconds)
        else { throw StoreError.invalidReference }
        try Self.requireReal(directory, isDirectory: true)
        try Self.requireReal(conditioningFile, isDirectory: false)
        let size = try conditioningFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (8...ChatterboxVoiceFile.maximumBytes).contains(size) else { throw StoreError.damagedVoice }
        let data = try Data(contentsOf: conditioningFile)
        guard data.count <= ChatterboxVoiceFile.maximumBytes else { throw StoreError.damagedVoice }
        let id = UUID()
        let pending = directory.appendingPathComponent(".pending-" + id.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: pending) } }
        let file = pending.appendingPathComponent("conditioning.safetensors")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try ChatterboxVoiceFile.validate(at: file)
        let saved = ChatterboxSavedVoice(id: id, name: label, language: language, createdAt: Date(),
            modelFamily: Self.modelFamily, schemaVersion: 1, conditioningSHA256: Self.hash(data),
            conditioningBytes: data.count, origin: origin, referenceSHA256: referenceSHA256,
            referenceSeconds: referenceSeconds, listeningAccepted: listeningAccepted)
        try JSONEncoder().encode(saved).write(to: pending.appendingPathComponent("voice.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.appendingPathComponent("voice.json").path)
        // Final synchronous commit: cancellation before this point leaves no voice;
        // after it, the returned UUID identifies the successfully saved profile.
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: pending, to: folder(id))
        committed = true
        return saved
    }

    public func voices() throws -> [ChatterboxSavedVoice] {
        try Self.requireReal(directory, isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]).compactMap { url in
                guard url.lastPathComponent.hasPrefix("voice-"),
                      let id = UUID(uuidString: String(url.lastPathComponent.dropFirst(6))) else { return nil }
                return try read(id)
            }.sorted { $0.createdAt < $1.createdAt }
    }

    public func voice(_ id: UUID) throws -> ChatterboxSavedVoice { try read(id) }

    public func rename(_ id: UUID, name: String) throws -> ChatterboxSavedVoice {
        try Task.checkCancellation()
        let old = try read(id), label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 80, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw StoreError.invalidName }
        let value = ChatterboxSavedVoice(id: old.id, name: label, language: old.language, createdAt: old.createdAt,
            modelFamily: old.modelFamily, schemaVersion: old.schemaVersion, conditioningSHA256: old.conditioningSHA256,
            conditioningBytes: old.conditioningBytes, origin: old.origin, referenceSHA256: old.referenceSHA256,
            referenceSeconds: old.referenceSeconds, listeningAccepted: old.listeningAccepted)
        let file = folder(id).appendingPathComponent("voice.json")
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return value
    }

    public func conditioningFile(for id: UUID, modelFamily: String = ChatterboxVoiceStore.modelFamily) throws -> URL {
        let value = try read(id)
        guard value.modelFamily == modelFamily else { throw StoreError.incompatibleModel }
        return folder(id).appendingPathComponent("conditioning.safetensors")
    }

    public func delete(_ id: UUID) throws {
        try Self.requireReal(directory, isDirectory: true)
        try Self.requireReal(folder(id), isDirectory: true)
        try FileManager.default.removeItem(at: folder(id))
    }

    private func read(_ id: UUID) throws -> ChatterboxSavedVoice {
        try Self.requireReal(directory, isDirectory: true)
        let path = folder(id)
        try Self.requireReal(path, isDirectory: true)
        let manifest = path.appendingPathComponent("voice.json")
        try Self.requireReal(manifest, isDirectory: false)
        guard (try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 16_384 else { throw StoreError.damagedVoice }
        let value = try JSONDecoder().decode(ChatterboxSavedVoice.self, from: Data(contentsOf: manifest))
        guard value.id == id, value.schemaVersion == 1, value.modelFamily == Self.modelFamily else { throw StoreError.incompatibleModel }
        let file = path.appendingPathComponent("conditioning.safetensors")
        try Self.requireReal(file, isDirectory: false)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) == value.conditioningBytes,
              (8...ChatterboxVoiceFile.maximumBytes).contains(value.conditioningBytes),
              Self.hash(try Data(contentsOf: file)) == value.conditioningSHA256 else { throw StoreError.damagedVoice }
        return value
    }

    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent("voice-" + id.uuidString.lowercased(), isDirectory: true) }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func requireReal(_ url: URL, isDirectory: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true,
              isDirectory ? values.isDirectory == true : values.isRegularFile == true else { throw StoreError.unsafePath }
    }
}
