import CryptoKit
import Foundation

public enum ChatterboxCacheError: Error, Equatable, Sendable {
    case invalidWindow, invalidBudget, unitTooLong, budgetExceeded, invalidEntry, unsafePath, incompleteUnit
}

/// One existing planner unit, with the exact installed model and reference identities.
public struct ChatterboxCacheUnit: Sendable {
    public let index: Int
    public let request: ChatterboxRequest
    public let key: String

    public init(index: Int, request: ChatterboxRequest, modelManifestSHA256: String,
                conditioningSHA256: String, rendererProfile: String = "automatic") throws {
        guard index >= 0 else { throw ChatterboxCacheError.invalidWindow }
        self.index = index
        self.request = request
        self.key = try request.cacheKey(modelManifestSHA256: modelManifestSHA256,
                                       conditioningSHA256: conditioningSHA256,
                                       rendererProfile: rendererProfile)
    }
}

public struct ChatterboxCachedUnit: Sendable {
    /// Carries the original source range, cast, language and expression settings.
    public let unit: ChatterboxCacheUnit
    public let file: URL
    public let frames: Int
    public var durationSeconds: TimeInterval { Double(frames) / 24_000 }
}

/// Optional completed-PCM cache for the audible unit plus at most two upcoming units.
/// Core ML's resident batch path can overlap decoding and synthesis; direct native
/// renderers return complete units sequentially. This cache creates no decoder.
///
/// The caller owns the playback-generation task: cancel and await it on seek,
/// chapter/voice changes or stop, then call with the new window. Only complete,
/// finite 24 kHz units are committed. A failed window may leave valid complete
/// entries to reuse; it never marks a partial unit ready or advances playback.
public actor ChatterboxLookaheadCache {
    private static let magic = Data("LBXCBX01".utf8)
    private static let overhead = 16 + 32
    private let directory: URL
    private let maximumBytes: Int
    private let maximumFrames: Int
    private let maximumEntries = 256
    private var occupied = false
    private var pendingSamples: [Float] = []
    private var pendingRequest = 0
    private var pendingChunk = 0
    private var nextReady = 0

    /// Use a dedicated, disposable app cache directory. Unrelated files are ignored.
    public init(directory: URL, maximumBytes: Int = 64 * 1_024 * 1_024,
                maximumUnitSeconds: TimeInterval = 120) throws {
        guard (52...512 * 1_024 * 1_024).contains(maximumBytes),
              maximumUnitSeconds.isFinite, maximumUnitSeconds >= 1.0 / 24_000,
              maximumUnitSeconds <= 120 else { throw ChatterboxCacheError.invalidBudget }
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumFrames = Int(maximumUnitSeconds * 24_000)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Cache hits do no model work. Missing units are rendered once in source order.
    /// The window is exactly current + 0...2 contiguous upcoming planner units.
    /// `onReady` announces the contiguous ready prefix immediately, so playback
    /// can start without waiting for both upcoming units. Its callback is awaited.
    public func prepareWindow(_ units: [ChatterboxCacheUnit], using narrator: ChatterboxNarrator,
                              onReady: (@Sendable (ChatterboxCachedUnit) async throws -> Void)? = nil) async throws -> [ChatterboxCachedUnit] {
        guard !occupied else { throw ChatterboxNarrationError.busy }
        guard (1...3).contains(units.count), let first = units.first,
              first.index <= Int.max - 2,
              units.enumerated().allSatisfy({ $0.element.index == first.index + $0.offset }) else {
            throw ChatterboxCacheError.invalidWindow
        }
        occupied = true
        defer {
            occupied = false
            pendingSamples.removeAll(keepingCapacity: false)
            pendingRequest = 0; pendingChunk = 0; nextReady = 0
        }
        try Task.checkCancellation()
        let protected = Set(units.map(\.key))
        var missing: [ChatterboxCacheUnit] = []
        var seen = Set<String>()
        for unit in units {
            if try cached(unit) == nil, seen.insert(unit.key).inserted { missing.append(unit) }
        }
        try await publishReadyPrefix(units, onReady: onReady)
        if !missing.isEmpty {
            let work = missing
            try await narrator.streamBatch(work.map(\.request)) { chunk in
                try Task.checkCancellation()
                try await self.consume(chunk, work: work, window: units, protected: protected, onReady: onReady)
            }
            guard pendingRequest == work.count, pendingSamples.isEmpty else { throw ChatterboxCacheError.incompleteUnit }
        }
        try Task.checkCancellation()
        return try units.map { unit in
            guard let value = try cached(unit) else { throw ChatterboxCacheError.incompleteUnit }
            return value
        }
    }

    public func samples(for unit: ChatterboxCacheUnit) throws -> [Float]? {
        guard let data = try validatedData(unit.key) else { return nil }
        return data.withUnsafeBytes { bytes in
            let count = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            return (0..<count).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + $0 * 4, as: UInt32.self)))
            }
        }
    }

    private func consume(_ value: ChatterboxBatchChunk, work: [ChatterboxCacheUnit], window: [ChatterboxCacheUnit],
                         protected: Set<String>, onReady: (@Sendable (ChatterboxCachedUnit) async throws -> Void)?) async throws {
        try Task.checkCancellation()
        guard value.requestIndex == pendingRequest, value.chunkIndex == pendingChunk,
              work.indices.contains(value.requestIndex) else { throw ChatterboxCacheError.incompleteUnit }
        guard value.audio.samples.count <= maximumFrames - pendingSamples.count else { throw ChatterboxCacheError.unitTooLong }
        pendingSamples.append(contentsOf: value.audio.samples)
        pendingChunk += 1
        if value.isFinalChunk {
            try Task.checkCancellation()
            try store(pendingSamples, key: work[value.requestIndex].key, protected: protected)
            pendingSamples.removeAll(keepingCapacity: false)
            pendingRequest += 1; pendingChunk = 0
            try await publishReadyPrefix(window, onReady: onReady)
        }
    }

    private func publishReadyPrefix(_ units: [ChatterboxCacheUnit],
                                    onReady: (@Sendable (ChatterboxCachedUnit) async throws -> Void)?) async throws {
        while nextReady < units.count, let entry = try cached(units[nextReady]) {
            try Task.checkCancellation()
            nextReady += 1
            if let onReady { try await onReady(entry) }
        }
    }

    private func cached(_ unit: ChatterboxCacheUnit) throws -> ChatterboxCachedUnit? {
        guard let data = try validatedData(unit.key) else { return nil }
        let frames = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self))) }
        let file = try path(unit.key)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return ChatterboxCachedUnit(unit: unit, file: file, frames: frames)
    }

    private func path(_ key: String) throws -> URL {
        guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ChatterboxCacheError.unsafePath
        }
        let file = directory.appendingPathComponent(key + ".cbpcm")
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ChatterboxCacheError.unsafePath
        }
        return file
    }

    /// Invalid disposable cache entries are removed and regenerated, never played.
    private func validatedData(_ key: String) throws -> Data? {
        let file = try path(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= Self.overhead + 4, size <= Self.overhead + maximumFrames * 4 else {
            try FileManager.default.removeItem(at: file); return nil
        }
        let data = try Data(contentsOf: file)
        let valid = data.withUnsafeBytes { bytes -> Bool in
            guard data.count == size, data.prefix(8) == Self.magic else { return false }
            let rate = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let frames = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            guard rate == 24_000, frames > 0, frames <= maximumFrames,
                  data.count == Self.overhead + frames * 4,
                  SHA256.hash(data: data.dropLast(32)).elementsEqual(data.suffix(32)) else { return false }
            return (0..<frames).allSatisfy {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + $0 * 4, as: UInt32.self))).isFinite
            }
        }
        guard valid else { try FileManager.default.removeItem(at: file); return nil }
        return data
    }

    private func store(_ samples: [Float], key: String, protected: Set<String>) throws {
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), samples.count <= maximumFrames else {
            throw ChatterboxCacheError.invalidEntry
        }
        var data = Self.magic
        for value in [UInt32(24_000), UInt32(samples.count)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        #if _endian(little)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        #else
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        #endif
        data.append(contentsOf: SHA256.hash(data: data))
        let file = try path(key)
        try makeRoom(for: data.count, replacing: file, protected: protected)
        try Task.checkCancellation()
        try data.write(to: file, options: .atomic)
    }

    private func makeRoom(for required: Int, replacing target: URL, protected: Set<String>) throws {
        guard required <= maximumBytes else { throw ChatterboxCacheError.budgetExceeded }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        var entries: [(file: URL, key: String, size: Int, date: Date)] = []
        for file in files where file.pathExtension == "cbpcm" && file != target {
            let key = file.deletingPathExtension().lastPathComponent
            guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            entries.append((file, key, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var bytes = entries.reduce(0) { $0 + $1.size }
        var count = entries.count
        for entry in entries.sorted(by: { $0.date < $1.date }) where !protected.contains(entry.key) {
            if bytes + required <= maximumBytes, count < maximumEntries { break }
            try FileManager.default.removeItem(at: entry.file)
            bytes -= entry.size; count -= 1
        }
        guard bytes + required <= maximumBytes, count < maximumEntries else { throw ChatterboxCacheError.budgetExceeded }
    }
}
