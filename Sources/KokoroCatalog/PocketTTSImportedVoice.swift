import CryptoKit
import Foundation

/// A validated, immutable Max voice package. Reopen through the store after app
/// launch; persist `id` in book settings, not this process-local file handle.
/// A .libroxvoice file is safetensors with a `librox.voice` metadata record.
public struct PocketTTSImportedVoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let language: String
    public let referenceFrames: Int
    public let sha256: String
    public let attribution: String
    private let file: URL

    public struct Metadata: Codable, Sendable {
        public let formatVersion: Int
        public let name: String
        public let language: String
        public let modelIdentity: String
        public let modelSHA256: String
        public let attribution: String

        public init(name: String, language: String, modelIdentity: String,
                    modelSHA256: String, attribution: String) {
            formatVersion = 1; self.name = name; self.language = language
            self.modelIdentity = modelIdentity; self.modelSHA256 = modelSHA256
            self.attribution = attribution
        }
    }

    public enum ImportError: LocalizedError {
        case invalidPackage, incompatibleModel, invalidTensor, missingOrChangedVoice, unsupportedStyle
        public var errorDescription: String? {
            switch self {
            case .invalidPackage: "This is not a supported Librox voice package."
            case .incompatibleModel: "This voice was exported for a different Max model or language."
            case .invalidTensor: "This voice contains invalid or unsupported voice tensors."
            case .missingOrChangedVoice: "The imported voice is missing or has changed. Import it again."
            case .unsupportedStyle: "Imported voices support their original delivery only."
            }
        }
    }

    /// Disk work: run off the main actor. No model allocation or code execution.
    public static func inspect(at url: URL) throws -> Self {
        try inspect(data: read(url), at: url)
    }

    /// Export tooling can wrap an upstream voice state without changing tensors.
    /// The returned bytes are the complete single-file .libroxvoice package.
    public static func package(state: Data, metadata: Metadata) throws -> Data {
        let (header, start) = try header(state)
        var object = header
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        object["__metadata__"] = ["librox.voice": String(decoding: try encoder.encode(metadata), as: UTF8.self)]
        var encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        while encoded.count % 8 != 0 { encoded.append(0x20) }
        var size = UInt64(encoded.count).littleEndian
        var result = withUnsafeBytes(of: &size) { Data($0) }
        result.append(encoded); result.append(state[start...])
        _ = try decode(result)
        return result
    }

    /// Used by both backends. Verify the exact selected bytes on every render;
    /// never fall back to a stock voice if an imported file disappears/changes.
    package func state() throws -> PocketTTSImportedVoiceState {
        let data: Data
        do { data = try Self.read(file) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ImportError.missingOrChangedVoice }
        guard Self.digest(data) == sha256 else { throw ImportError.missingOrChangedVoice }
        return try Self.decode(data).state
    }

    package static func resolve(_ id: String) -> Self? {
        PocketTTSVoiceRegistry.shared.voices.first { $0.id == id }
    }

    fileprivate static func inspect(data: Data, at url: URL) throws -> Self {
        let decoded = try decode(data), hash = digest(data)
        // URL-safe base64 retains all 256 hash bits while fitting the existing
        // 64-byte persisted BookVoiceCast identifier contract.
        let identity = Data(SHA256.hash(data: data)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self(id: "pocket-custom-\(decoded.metadata.language)-\(identity)",
            name: decoded.metadata.name, language: decoded.metadata.language,
            referenceFrames: decoded.state.frames, sha256: hash,
            attribution: decoded.metadata.attribution, file: url.standardizedFileURL)
    }

    fileprivate static let maximumBytes = 32 * 1_024 * 1_024
    fileprivate static func read(_ url: URL) throws -> Data {
        try Task.checkCancellation()
        // Foundation URLs cache resource values; an import URL may be reused after a file replacement.
        var fresh = url; fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (8...maximumBytes).contains(size) else { throw ImportError.invalidPackage }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // Bound the read as well as the stat, including a concurrently grown file.
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == size, data.count <= maximumBytes else { throw ImportError.invalidPackage }
        return data
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func header(_ data: Data) throws -> ([String: Any], Int) {
        guard (8...maximumBytes).contains(data.count) else { throw ImportError.invalidPackage }
        let n = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard n > 0, n <= 65_536, n <= UInt64(data.count - 8),
              let object = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + Int(n)))) as? [String: Any]
        else { throw ImportError.invalidPackage }
        return (object, 8 + Int(n))
    }

    private struct Tensor: Decodable {
        let dtype: String
        let shape: [Int]
        let data_offsets: [Int]
    }
    private static func decode(_ data: Data) throws -> (metadata: Metadata, state: PocketTTSImportedVoiceState) {
        let (header, start) = try header(data)
        guard let metadata = header["__metadata__"] as? [String: String],
              let json = metadata["librox.voice"], json.utf8.count <= 8_192 else { throw ImportError.invalidPackage }
        let info = try JSONDecoder().decode(Metadata.self, from: Data(json.utf8))
        guard info.formatVersion == 1,
              !info.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              info.name.utf8.count <= 128, !info.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              info.attribution.utf8.count <= 4_096 else { throw ImportError.invalidPackage }
        guard info.modelIdentity == PocketTTSCatalog.identity, PocketTTSCatalog.languages.contains(info.language),
              let model = try PocketTTSCatalog.manifest(language: info.language).installedFiles.first(where: {
                  $0.path == "\(info.language)/model.safetensors"
              }), info.modelSHA256 == model.sha256 else { throw ImportError.incompatibleModel }
        var object = header; object.removeValue(forKey: "__metadata__")
        let tensors = try JSONDecoder().decode([String: Tensor].self,
            from: JSONSerialization.data(withJSONObject: object))
        var expected = Set<String>(), ranges: [Range<Int>] = [], layers: [PocketTTSImportedVoiceState.Layer] = []
        var frames: Int?
        func validate(_ t: Tensor, dtype: String, shape: [Int], count: Int) throws -> Int {
            guard t.dtype == dtype, t.shape == shape, t.data_offsets.count == 2,
                  t.data_offsets[0] >= 0, t.data_offsets[1] >= t.data_offsets[0],
                  t.data_offsets[1] <= data.count - start,
                  t.data_offsets[1] - t.data_offsets[0] == count else { throw ImportError.invalidTensor }
            ranges.append(t.data_offsets[0]..<t.data_offsets[1])
            return start + t.data_offsets[0]
        }
        for i in 0..<6 {
            try Task.checkCancellation()
            let prefix = "transformer.layers.\(i).self_attn/"
            expected.formUnion([prefix + "cache", prefix + "offset"])
            guard let cache = tensors[prefix + "cache"], let offset = tensors[prefix + "offset"],
                  cache.shape.count == 5, (1...512).contains(cache.shape[2]) else { throw ImportError.invalidTensor }
            let capacity = cache.shape[2]
            let base = try validate(cache, dtype: "F32", shape: [2,1,capacity,16,64], count: 2 * capacity * 1024 * 4)
            let at = try validate(offset, dtype: "I64", shape: [1], count: 8)
            let n = data.withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: Int64.self)) }
            guard n > 0, n <= capacity, frames == nil || frames == Int(n) else { throw ImportError.invalidTensor }
            frames = Int(n)
            if let pad = tensors[prefix + "pad"] {
                expected.insert(prefix + "pad")
                let at = try validate(pad, dtype: "I64", shape: [1], count: 8)
                guard data.withUnsafeBytes({ Int64(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: Int64.self)) }) == 0
                else { throw ImportError.invalidTensor }
            }
            // Decode into immutable host arrays, before either inference backend
            // sees the input. Shape is [1, heads, frames, headDimension].
            var pair: [[Float]] = []
            for kv in 0..<2 {
                var values = [Float](repeating: 0, count: Int(n) * 1024)
                try data.withUnsafeBytes { bytes in
                    for frame in 0..<capacity { for head in 0..<16 { for dim in 0..<64 {
                        let at = base + ((kv * capacity + frame) * 1024 + head * 64 + dim) * 4
                        let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                        guard value.isFinite else { throw ImportError.invalidTensor }
                        if frame < Int(n) { values[(head * Int(n) + frame) * 64 + dim] = value }
                    } } }
                }
                pair.append(values)
            }
            layers.append(.init(key: pair[0], value: pair[1]))
        }
        guard Set(tensors.keys) == expected else { throw ImportError.invalidTensor }
        var end = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == end else { throw ImportError.invalidTensor }
            end = range.upperBound
        }
        guard end == data.count - start, let frames else { throw ImportError.invalidTensor }
        return (info, .init(frames: frames, layers: layers))
    }
}

package struct PocketTTSImportedVoiceState: Sendable {
    package struct Layer: Sendable { package let key: [Float]; package let value: [Float] }
    package let frames: Int
    package let layers: [Layer]
}

/// App-owned storage, separate from downloaded language packs. Successful import
/// and reopen register validated voices with the existing catalog and backends.
/// Call `voices()` at launch before restoring persisted voice selections.
public actor PocketTTSVoiceStore {
    private let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }

    @discardableResult
    public func importVoice(from package: URL) throws -> PocketTTSImportedVoice {
        let bytes = try PocketTTSImportedVoice.read(package)
        let inspected = try PocketTTSImportedVoice.inspect(data: bytes, at: package)
        try prepareDirectory()
        let destination = directory.appendingPathComponent(inspected.sha256 + ".safetensors")
        if FileManager.default.fileExists(atPath: destination.path),
           let existing = try? PocketTTSImportedVoice.inspect(at: destination), existing.id == inspected.id {
            PocketTTSVoiceRegistry.shared.register(existing, in: directory)
            return existing
        }
        try Task.checkCancellation()
        try bytes.write(to: destination, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], atPath: destination.path)
        #endif
        let voice = try PocketTTSImportedVoice.inspect(data: bytes, at: destination)
        PocketTTSVoiceRegistry.shared.register(voice, in: directory)
        return voice
    }

    /// A corrupt file is an error, not a silent substitution or disappearance.
    public func voices() throws -> [PocketTTSImportedVoice] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            PocketTTSVoiceRegistry.shared.replace([], in: directory)
            return []
        }
        try prepareDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let voices: [PocketTTSImportedVoice] = try files
            .filter { $0.pathExtension == "safetensors" }.map { url -> PocketTTSImportedVoice in
                let voice = try PocketTTSImportedVoice.inspect(at: url)
                guard url.deletingPathExtension().lastPathComponent == voice.sha256 else {
                    throw PocketTTSImportedVoice.ImportError.missingOrChangedVoice
                }
                return voice
            }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        PocketTTSVoiceRegistry.shared.replace(voices, in: directory)
        return voices
    }

    /// Does not rewrite saved book selections; a removed ID remains unavailable.
    public func remove(_ voice: PocketTTSImportedVoice) throws {
        try prepareDirectory()
        let url = directory.appendingPathComponent(voice.sha256 + ".safetensors")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        PocketTTSVoiceRegistry.shared.remove(voice.id, in: directory)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().path == directory.path,
              try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isSymbolicLink != true
        else { throw PocketTTSImportedVoice.ImportError.invalidPackage }
    }
}

/// Synchronous catalog reads must work from existing nonisolated public APIs.
/// Only validated descriptors are registered; disk/tensor work stays outside the
/// lock. Store ownership keeps one directory's refresh/removal from affecting
/// another. Every backend still verifies the selected file at render time.
package final class PocketTTSVoiceRegistry: @unchecked Sendable {
    package static let shared = PocketTTSVoiceRegistry()
    private let lock = NSLock()
    private var stores: [String: [String: PocketTTSImportedVoice]] = [:]
    package var voices: [PocketTTSImportedVoice] {
        lock.withLock {
            var seen = Set<String>()
            return stores.keys.sorted().flatMap { stores[$0]!.values }
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        }
    }
    func register(_ voice: PocketTTSImportedVoice, in directory: URL) {
        lock.withLock { stores[directory.path, default: [:]][voice.id] = voice }
    }
    package func replace(_ voices: [PocketTTSImportedVoice], in directory: URL) {
        lock.withLock {
            if voices.isEmpty { stores.removeValue(forKey: directory.path) }
            else { stores[directory.path] = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0) }) }
        }
    }
    func remove(_ id: String, in directory: URL) {
        lock.withLock {
            stores[directory.path]?.removeValue(forKey: id)
            if stores[directory.path]?.isEmpty == true { stores.removeValue(forKey: directory.path) }
        }
    }
}
