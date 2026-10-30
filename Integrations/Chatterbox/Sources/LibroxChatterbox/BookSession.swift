import Foundation
import KokoroPronunciation
import CryptoKit
import ChatterboxCoreML

public struct ChatterboxPreparedPassage: Sendable {
    public let index: Int
    public let unit: ChatterboxDirectedUnit
    /// Includes library-owned boundary timing; ready for host playback.
    public let samples: [Float]
    public let cacheHit: Bool
    public let timings: ChatterboxChunkTimings?
    public let generatedFrames: Int
    public let generationID: UUID
}

/// The host supplies bounded document text/settings and consumes ready PCM.
/// Planning, current-plus-two preparation, caching and cadence remain in the kit.
/// Cancel and await stream before changing text/voice/book or discarding a session.
public actor ChatterboxBookSession {
    public enum Preparation: Sendable {
        /// Host acknowledges completed playback; the kit permits current + two.
        case playbackLookahead
        /// Explicit finite preparation of the supplied bounded excerpt.
        case finiteExcerpt
    }
    private let narrator: ChatterboxNarrator
    private let cache: ChatterboxLookaheadCache
    private let manifestSHA256: String
    private let rendererProfile: String
    private var occupied = false
    private var cadence = ChatterboxConversationSession()
    private var generationID: UUID?
    private var completedPlayback = -1
    private var highestPublished = -1
    private var waitingIndex = 0
    private var playbackWaiter: CheckedContinuation<Void, Error>?

    public init(narrator: ChatterboxNarrator, cacheDirectory: URL,
                modelManifestSHA256: String, rendererProfile: String,
                maximumCacheBytes: Int = 64 * 1_024 * 1_024) throws {
        self.narrator = narrator
        self.cache = try ChatterboxLookaheadCache(directory: cacheDirectory, maximumBytes: maximumCacheBytes)
        self.manifestSHA256 = modelManifestSHA256
        self.rendererProfile = rendererProfile
    }

    public func stream(_ source: String, language: String, narratorID: String,
                       conditioningFiles: [String: URL], conditioningSHA256: [String: String]? = nil,
                       direction: ChatterboxBookDirector.Direction = .storyteller,
                       grouping: ChatterboxBookDirector.Grouping = .compatibleNarration(), seed: UInt64? = nil,
                       reviewedDialogue: [DialogueAnnotation]? = nil,
                       performanceDirections: ChatterboxPerformanceDirections? = nil, characterVoices: [String: String] = [:],
                       preparation: Preparation = .playbackLookahead,
                       receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        guard !occupied else { throw ChatterboxNarrationError.busy }
        guard source.utf8.count <= 32_768 else { throw ChatterboxNarrationError.textTooLong }
        occupied = true
        let generation = UUID()
        generationID = generation; completedPlayback = -1; highestPublished = -1
        let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("librox-voice-" + UUID().uuidString)
        var ownsSnapshots = false
        defer {
            occupied = false; generationID = nil
            playbackWaiter?.resume(throwing: CancellationError()); playbackWaiter = nil
            if ownsSnapshots { try? FileManager.default.removeItem(at: snapshots) }
        }
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        ownsSnapshots = true
        cadence.reset()
        try Task.checkCancellation()
        let originalUnits = try ChatterboxBookDirector.plan(source, language: language, narratorID: narratorID,
            conditioningFiles: conditioningFiles, direction: direction, grouping: grouping,
            reviewedDialogue: reviewedDialogue, performanceDirections: performanceDirections, characterVoices: characterVoices, seed: seed)
        var hashes: [String: String] = [:]
        var frozenFiles: [String: URL] = [:]
        for id in Set(originalUnits.compactMap { $0.request.sourceContext?.voiceID }) {
            guard let file = conditioningFiles[id] else { throw ChatterboxNarrationError.missingVoiceConditioning(id) }
            let input = try FileHandle(forReadingFrom: file)
            let data: Data
            do { data = try input.read(upToCount: ChatterboxVoiceFile.maximumBytes + 1) ?? Data(); try input.close() }
            catch { try? input.close(); throw error }
            guard !data.isEmpty, data.count <= ChatterboxVoiceFile.maximumBytes else { throw ChatterboxCacheError.invalidEntry }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let expected = conditioningSHA256?[id], expected != hash { throw ChatterboxCacheError.invalidEntry }
            hashes[id] = hash
            let snapshot = snapshots.appendingPathComponent(hash + ".safetensors")
            try data.write(to: snapshot, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            try ChatterboxVoiceFile.validate(at: snapshot)
            frozenFiles[id] = snapshot
        }
        let units = try originalUnits.map { unit -> ChatterboxDirectedUnit in
            let r = unit.request
            guard let id = r.sourceContext?.voiceID, let file = frozenFiles[id] else { throw ChatterboxCacheError.invalidEntry }
            let request = try ChatterboxRequest(text: r.text, language: r.language, conditioningFile: file,
                exaggeration: r.exaggeration, guidance: r.guidance, temperature: r.temperature,
                maxTokens: r.maxTokens, seed: r.seed, sourceContext: r.sourceContext)
            return .init(request: request, timingContext: unit.timingContext, performance: unit.performance,
                         sourceFragments: unit.sourceFragments)
        }
        let profile = rendererProfile + ":" + ChatterboxBookDirector.revision + ":" + grouping.cacheRevision
        var base = 0
        while base < units.count {
            try Task.checkCancellation()
            if case .playbackLookahead = preparation { try await awaitPlaybackPermit(for: base, generation: generation) }
            var end = min(base + 3, units.count)
            if case .playbackLookahead = preparation { end = min(end, completedPlayback + 4) }
            let window = try (base..<end).map { index in
                let request = units[index].request
                guard let id = request.sourceContext?.voiceID, let hash = hashes[id] else {
                    throw ChatterboxNarrationError.missingVoiceConditioning(narratorID)
                }
                return try ChatterboxCacheUnit(index: index, request: request,
                    modelManifestSHA256: manifestSHA256, conditioningSHA256: hash, rendererProfile: profile)
            }
            _ = try await cache.prepareWindow(window, using: narrator) { ready in
                try Task.checkCancellation()
                guard let samples = try await self.cache.samples(for: ready.unit) else { throw ChatterboxCacheError.incompleteUnit }
                try await self.deliver(samples, ready: ready, unit: units[ready.unit.index], receive: receive)
            }
            base = end
        }
    }

    /// Thin playback integration: call when a published passage finishes playing.
    /// Stale generations, future positions and out-of-order acknowledgements fail closed.
    @discardableResult public func didFinishPlaying(index: Int, generationID: UUID) -> Bool {
        guard self.generationID == generationID, index == completedPlayback + 1, index <= highestPublished else { return false }
        completedPlayback = index
        if waitingIndex <= completedPlayback + 3 {
            playbackWaiter?.resume(); playbackWaiter = nil
        }
        return true
    }

    private func awaitPlaybackPermit(for index: Int, generation: UUID) async throws {
        try Task.checkCancellation()
        guard index > completedPlayback + 3 else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waitingIndex = index; playbackWaiter = continuation }
            }
        } onCancel: { Task { await self.cancelPlaybackWait(generation) } }
        try Task.checkCancellation()
    }

    private func cancelPlaybackWait(_ generation: UUID) {
        guard generationID == generation else { return }
        playbackWaiter?.resume(throwing: CancellationError()); playbackWaiter = nil
    }

    private func deliver(_ raw: [Float], ready: ChatterboxCachedUnit, unit: ChatterboxDirectedUnit,
                         receive: @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        var samples = raw
        try cadence.completeUnit(&samples, context: unit.timingContext)
        try Task.checkCancellation()
        guard let generationID else { throw CancellationError() }
        highestPublished = ready.unit.index
        try await receive(.init(index: ready.unit.index, unit: unit, samples: samples,
                                cacheHit: ready.cacheHit, timings: ready.timings, generatedFrames: raw.count,
                                generationID: generationID))
        try Task.checkCancellation()
    }
}
