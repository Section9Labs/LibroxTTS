import Foundation
import Testing
@testable import LibroxChatterbox

private actor LookaheadCalls {
    var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}

private func cacheUnit(_ index: Int, conditioning: String = String(repeating: "b", count: 64)) throws -> ChatterboxCacheUnit {
    try ChatterboxCacheUnit(index: index, request: ChatterboxRequest(text: "Unit \(index).", language: "en"),
        modelManifestSHA256: String(repeating: "a", count: 64), conditioningSHA256: conditioning)
}

private func cacheDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func cacheNarrator(_ calls: LookaheadCalls, samples: [Float] = [0.25, -0.5, 0, 1]) -> ChatterboxNarrator {
    ChatterboxNarrator(batchSource: { requests, receive in
        for (index, request) in requests.enumerated() {
            await calls.add(request.text)
            try await receive(ChatterboxBatchChunk(requestIndex: index, chunkIndex: 0, isFinalChunk: true,
                request: request, audio: ChatterboxAudioChunk(samples: samples)))
        }
    })
}

@Test func lookaheadCachesCurrentPlusTwoAndSurvivesReload() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let calls = LookaheadCalls(), narrator = cacheNarrator(calls)
    let units = try (0..<3).map { try cacheUnit($0) }
    let cache = try ChatterboxLookaheadCache(directory: directory)
    let ready = try await cache.prepareWindow(units, using: narrator)
    #expect(ready.map(\.unit.index) == [0, 1, 2])
    #expect(ready.allSatisfy { $0.frames == 4 && $0.durationSeconds == 4.0 / 24_000 })
    #expect(await calls.texts == units.map(\.request.text))
    #expect(try await cache.samples(for: units[1]) == [0.25, -0.5, 0, 1])
    // A fresh instance and unloaded narrator prove that cache hits bypass inference.
    let restored = try ChatterboxLookaheadCache(directory: directory)
    #expect(try await restored.prepareWindow(units, using: ChatterboxNarrator()).count == 3)
    #expect(await calls.texts.count == 3)
}

@Test func lookaheadAdvancesOneUnitAndEvictsOnlyUnprotectedOwnedFiles() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let unrelated = directory.appendingPathComponent("keep.txt")
    try Data("preserve".utf8).write(to: unrelated)
    let calls = LookaheadCalls(), narrator = cacheNarrator(calls)
    let units = try (0..<4).map { try cacheUnit($0) }
    let cache = try ChatterboxLookaheadCache(directory: directory, maximumBytes: 3 * 64)
    _ = try await cache.prepareWindow(Array(units[0...2]), using: narrator)
    _ = try await cache.prepareWindow(Array(units[1...3]), using: narrator)
    #expect(await calls.texts == units.map(\.request.text))
    #expect(try await cache.samples(for: units[0]) == nil)
    for unit in units[1...3] { #expect(try await cache.samples(for: unit) != nil) }
    #expect(try String(contentsOf: unrelated, encoding: .utf8) == "preserve")
}

@Test func lookaheadRejectsOversizedOrNoncontiguousWindowBeforeInference() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let calls = LookaheadCalls(), narrator = cacheNarrator(calls)
    let cache = try ChatterboxLookaheadCache(directory: directory)
    let all = try (0..<4).map { try cacheUnit($0) }
    for units in [[], all, [all[0], all[2]]] {
        await #expect(throws: ChatterboxCacheError.invalidWindow) { try await cache.prepareWindow(units, using: narrator) }
    }
    #expect(await calls.texts.isEmpty)
}

@Test func lookaheadChecksIntegrityAndReferenceIdentity() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let calls = LookaheadCalls(), narrator = cacheNarrator(calls)
    let cache = try ChatterboxLookaheadCache(directory: directory)
    let unit = try cacheUnit(0)
    let ready = try await cache.prepareWindow([unit], using: narrator)
    var broken = try Data(contentsOf: ready[0].file); broken[16] ^= 1
    try broken.write(to: ready[0].file, options: .atomic)
    _ = try await cache.prepareWindow([unit], using: narrator)
    #expect(await calls.texts.count == 2)
    let otherVoice = try cacheUnit(0, conditioning: String(repeating: "c", count: 64))
    #expect(otherVoice.key != unit.key)
    _ = try await cache.prepareWindow([otherVoice], using: narrator)
    #expect(await calls.texts.count == 3)
}

@Test func lookaheadAnnouncesCurrentImmediatelyAndCachedGapsInOrder() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try ChatterboxLookaheadCache(directory: directory)
    let units = try (0..<3).map { try cacheUnit($0) }
    _ = try await cache.prepareWindow([units[1]], using: cacheNarrator(LookaheadCalls()))
    let ready = LookaheadCalls()
    let narrator = ChatterboxNarrator(batchSource: { requests, receive in
        #expect(requests.map(\.text) == [units[0].request.text, units[2].request.text])
        for (index, request) in requests.enumerated() {
            if index == 1 {
                // Current audio and the cached next unit were delivered BEFORE
                // the last unit started, without waiting for the full window.
                #expect(await ready.texts == ["0", "1"])
            }
            try await receive(ChatterboxBatchChunk(requestIndex: index, chunkIndex: 0, isFinalChunk: true,
                request: request, audio: ChatterboxAudioChunk(samples: [1])))
        }
    })
    _ = try await cache.prepareWindow(units, using: narrator) { entry in
        let decoded = try await cache.samples(for: entry.unit)
        #expect(decoded != nil)
        await ready.add(String(entry.unit.index))
    }
    #expect(await ready.texts == ["0", "1", "2"])
}

@Test func lookaheadNeverCommitsPartialOrOverlongUnits() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let unit = try cacheUnit(0), calls = LookaheadCalls()
    let cache = try ChatterboxLookaheadCache(directory: directory, maximumUnitSeconds: 1.0 / 24_000)
    await #expect(throws: ChatterboxCacheError.unitTooLong) {
        try await cache.prepareWindow([unit], using: cacheNarrator(calls, samples: [0, 1]))
    }
    #expect(try await cache.samples(for: unit) == nil)
    let incomplete = ChatterboxNarrator(batchSource: { requests, receive in
        try await receive(ChatterboxBatchChunk(requestIndex: 0, chunkIndex: 0, isFinalChunk: false,
            request: requests[0], audio: ChatterboxAudioChunk(samples: [0])))
    })
    await #expect(throws: ChatterboxCacheError.incompleteUnit) { try await cache.prepareWindow([unit], using: incomplete) }
    #expect(try await cache.samples(for: unit) == nil)
    // Failed work releases both busy leases and clears partial accumulation.
    #expect(try await cache.prepareWindow([unit], using: cacheNarrator(calls, samples: [1])).count == 1)
}

@Test(.timeLimit(.minutes(1))) func lookaheadCancellationDiscardsPartialUnit() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try ChatterboxLookaheadCache(directory: directory), unit = try cacheUnit(0)
    let (signal, continuation) = AsyncStream<Void>.makeStream()
    let narrator = ChatterboxNarrator(batchSource: { requests, receive in
        try await receive(ChatterboxBatchChunk(requestIndex: 0, chunkIndex: 0, isFinalChunk: false,
            request: requests[0], audio: ChatterboxAudioChunk(samples: [0])))
        continuation.yield(()); continuation.finish()
        try await Task.sleep(for: .seconds(60))
    })
    let task = Task { try await cache.prepareWindow([unit], using: narrator) }
    for await _ in signal { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await cache.samples(for: unit) == nil)
    try await narrator.unload()
}

@Test func lookaheadPreservesProtectedWindowWhenDiskBudgetIsTooSmall() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try ChatterboxLookaheadCache(directory: directory, maximumBytes: 64)
    let units = try (0..<2).map { try cacheUnit($0) }
    await #expect(throws: ChatterboxCacheError.budgetExceeded) {
        try await cache.prepareWindow(units, using: cacheNarrator(LookaheadCalls()))
    }
    #expect(try await cache.samples(for: units[0]) != nil)
    #expect(try await cache.samples(for: units[1]) == nil)
}

@Test func lookaheadRefusesSymlinkWithoutTouchingItsTarget() async throws {
    let directory = try cacheDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("original.txt")
    try Data("preserve".utf8).write(to: target)
    let unit = try cacheUnit(0)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(unit.key + ".cbpcm"), withDestinationURL: target)
    let cache = try ChatterboxLookaheadCache(directory: directory)
    await #expect(throws: ChatterboxCacheError.unsafePath) {
        try await cache.prepareWindow([unit], using: cacheNarrator(LookaheadCalls()))
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
}
