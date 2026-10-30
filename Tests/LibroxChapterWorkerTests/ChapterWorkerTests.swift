import Foundation
import Testing
import CryptoKit
@testable import LibroxChapterWorker

private let partition = String(repeating: "a", count: 64)
private func request(voice: String = "stock", profile: String = "standard:logical-layout:cpu-acoustics") throws -> ChapterRenderRequest {
    try .init(accountPartition: partition,
        source: .init(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:7",
                      textSHA256: String(repeating: "c", count: 64), extractionRevision: "epub-1", utf16Length: 40),
        recipe: .init(language: "es", stockVoiceID: voice, conditioningSHA256: String(repeating: "d", count: 64),
                      modelSHA256: String(repeating: "e", count: 64), rendererProfile: profile,
                      plannerRevision: "chapter-1", expressionSHA256: String(repeating: "f", count: 64),
                      synthesisOptionsSHA256: String(repeating: "9", count: 64),
                      seedPolicy: "fixed-42", watermarkRevision: "perth-1"))
}
private func artifact(_ request: ChapterRenderRequest, bytes: Data = Data([1, 2, 3])) throws -> ChapterArtifactManifest {
    .init(renderKey: try request.renderKey(), audioSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
          audioByteCount: Int64(bytes.count), decodedFrameCount: 240,
          codecRevision: "wav-f32-1", units: [
            .init(source: .init(offset: 0, length: 20), fragments: [.init(offset: 0, length: 9), .init(offset: 10, length: 10)],
                  startFrame: 0, frameCount: 240)])
}

@Test func contentKeysRoundTripAndSeparateAudiblePolicies() throws {
    let a = try request()
    let roundTrip = try JSONDecoder().decode(ChapterRenderRequest.self, from: JSONEncoder().encode(a))
    #expect(try a.renderKey() == roundTrip.renderKey())
    #expect(try a.renderKey() != request(voice: "another-stock").renderKey())
    #expect(try a.renderKey() != request(profile: "standard:logical-layout:qualified-gpu-acoustics").renderKey())
    let otherAccount = try ChapterRenderRequest(accountPartition: String(repeating: "1", count: 64), source: a.source, recipe: a.recipe)
    #expect(try otherAccount.renderKey() == a.renderKey()) // separate account partition is still mandatory
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
    json["accountPartition"] = "not-a-hash"
    let malformed = try JSONDecoder().decode(ChapterRenderRequest.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: ChapterWorkerError.invalidIdentity) { try malformed.renderKey() }
    json["accountPartition"] = partition; json["schemaVersion"] = 999
    let unknown = try JSONDecoder().decode(ChapterRenderRequest.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(throws: ChapterWorkerError.invalidIdentity) { try unknown.renderKey() }
    #expect(throws: ChapterWorkerError.invalidIdentity) { try unknown.synthesisKey() }
}

@Test func sourceMapBindsExactUnicodeTextAndRejectsSurrogateSplit() throws {
    let text = "A🙂B", old = try request()
    let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    let r = try ChapterRenderRequest(accountPartition: partition,
        source: .init(bookSHA256: old.source.bookSHA256, chapterKey: "unicode", textSHA256: hash,
                      extractionRevision: "epub-1", utf16Length: text.utf16.count), recipe: old.recipe)
    func mapped(_ span: ChapterTextRange) throws -> ChapterArtifactManifest {
        .init(renderKey: try r.renderKey(), audioSHA256: String(repeating: "0", count: 64), audioByteCount: 4,
              decodedFrameCount: 240, codecRevision: "wav-f32-1", units: [
                .init(source: span, fragments: [span], startFrame: 0, frameCount: 240)])
    }
    try mapped(.init(offset: 0, length: 4)).validateSourceMap(text: text, for: r)
    #expect(throws: ChapterWorkerError.invalidManifest) {
        try mapped(.init(offset: 1, length: 1)).validateSourceMap(text: text, for: r)
    }
    #expect(throws: ChapterWorkerError.invalidIdentity) {
        try mapped(.init(offset: 0, length: 4)).validateSourceMap(text: "AxB", for: r)
    }
}

@Test func takeoverCancellationAndRenewalFenceLatePublication() throws {
    let r = try request(), device = UUID(), now = Date(timeIntervalSince1970: 1_000)
    var job = try ChapterJob(request: r, demandingDevice: device)
    let old = try job.acquire(workerID: UUID(), accountPartition: partition, now: now, leaseSeconds: 10, enabled: true)
    #expect(throws: ChapterWorkerError.busy) {
        try job.acquire(workerID: UUID(), accountPartition: partition, now: now, enabled: true)
    }
    let replacement = try job.acquire(workerID: UUID(), accountPartition: partition, now: now.addingTimeInterval(10), enabled: true)
    #expect(replacement.generation == old.generation + 1)
    #expect(throws: ChapterWorkerError.staleClaim) {
        try job.beginPublication(old, expectedIntentRevision: 0, accountPartition: partition, now: now.addingTimeInterval(11))
    }
    let renewed = try job.renew(replacement, accountPartition: partition, now: now.addingTimeInterval(12))
    #expect(throws: ChapterWorkerError.staleClaim) {
        try job.beginPublication(replacement, expectedIntentRevision: 0, accountPartition: partition, now: now.addingTimeInterval(13))
    }
    try job.beginPublication(renewed, expectedIntentRevision: 0, accountPartition: partition, now: now.addingTimeInterval(13))
    try job.cancelDemand(device, accountPartition: partition)
    #expect(throws: ChapterWorkerError.staleClaim) {
        try job.publish(artifact(r), token: renewed, expectedIntentRevision: 0, accountPartition: partition, now: now.addingTimeInterval(14))
    }
    #expect(job.phase == .cancelled && job.artifact == nil)
    try job.addDemand(device, accountPartition: partition)
    let next = try job.acquire(workerID: UUID(), accountPartition: partition, now: now.addingTimeInterval(15), enabled: true)
    #expect(next.generation > renewed.generation)
}

@Test func independentDemandsAndAccountIsolation() throws {
    let r = try request(), first = UUID(), second = UUID(), now = Date(timeIntervalSince1970: 100)
    var job = try ChapterJob(request: r, demandingDevice: first)
    try job.addDemand(second, accountPartition: partition)
    let claim = try job.acquire(workerID: UUID(), accountPartition: partition, now: now, enabled: true)
    try job.cancelDemand(first, accountPartition: partition)
    #expect(job.phase == .rendering && job.demandingDevices == [second])
    #expect(throws: ChapterWorkerError.accountMismatch) {
        try job.cancelDemand(second, accountPartition: String(repeating: "0", count: 64))
    }
    #expect(throws: ChapterWorkerError.staleClaim) {
        try job.beginPublication(claim, expectedIntentRevision: 1, accountPartition: partition, now: now)
    }
    try job.beginPublication(claim, expectedIntentRevision: job.intentRevision, accountPartition: partition, now: now)
    try job.publish(artifact(r), token: claim, expectedIntentRevision: job.intentRevision, accountPartition: partition, now: now)
    try job.cancelDemand(second, accountPartition: partition)
    #expect(job.phase == .ready && job.artifact != nil)
}

@Test func disabledWorkerCannotClaimAndRelinquishingFencesCallbacks() throws {
    let now = Date(timeIntervalSince1970: 100), r = try request()
    var job = try ChapterJob(request: r, demandingDevice: UUID())
    #expect(throws: ChapterWorkerError.disabled) {
        try job.acquire(workerID: UUID(), accountPartition: partition, now: now, enabled: false)
    }
    let claim = try job.acquire(workerID: UUID(), accountPartition: partition, now: now, enabled: true)
    try job.relinquishAfterJoining(claim, accountPartition: partition, now: now)
    #expect(job.phase == .queued && job.claim == nil)
    #expect(throws: ChapterWorkerError.staleClaim) {
        try job.beginPublication(claim, expectedIntentRevision: 0, accountPartition: partition, now: now)
    }
}

@Test func accountEpochRejectsDelayedCallbacksAfterSameAccountReturns() async throws {
    let gate = ChapterAccountSessionGate()
    let first = try await gate.open(accountPartition: partition)
    try await gate.validate(first)
    await gate.close()
    let second = try await gate.open(accountPartition: partition)
    #expect(first.epoch != second.epoch)
    await #expect(throws: ChapterWorkerError.accountMismatch) { try await gate.validate(first) }
    try await gate.validate(second)
    _ = try await gate.open(accountPartition: String(repeating: "0", count: 64))
    await #expect(throws: ChapterWorkerError.accountMismatch) { try await gate.validate(second) }
}

@Test func manifestRejectsMissingFramesBadRangesAndCorruptBytes() throws {
    let r = try request(), a = try artifact(r)
    try a.validate(for: r)
    let bad = ChapterArtifactManifest(renderKey: a.renderKey, audioSHA256: a.audioSHA256, audioByteCount: a.audioByteCount,
        decodedFrameCount: a.decodedFrameCount, codecRevision: a.codecRevision,
        units: [.init(source: .init(offset: 0, length: 20), fragments: [.init(offset: 18, length: 3)], startFrame: 1, frameCount: 239)])
    #expect(throws: ChapterWorkerError.invalidManifest) { try bad.validate(for: r) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("audio")
    try Data([1, 2, 3]).write(to: file)
    try a.verifyBytes(at: file, for: r)
    try Data([1, 2, 4]).write(to: file)
    #expect(throws: ChapterWorkerError.invalidManifest) { try a.verifyBytes(at: file, for: r) }
    let link = dir.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: ChapterWorkerError.invalidManifest) { try a.verifyBytes(at: link, for: r) }
}

@Test func deliveryChoiceSeparatesAssetsButPreservesSynthesisAndLegacyKeys() throws {
    let legacy = try request()
    let lossless = try ChapterRenderRequest(accountPartition: legacy.accountPartition, source: legacy.source,
                                            recipe: legacy.recipe, delivery: .lossless)
    let smaller = try ChapterRenderRequest(accountPartition: legacy.accountPartition, source: legacy.source,
                                           recipe: legacy.recipe, delivery: .smaller)
    #expect(lossless.recipe == smaller.recipe)
    #expect(try lossless.synthesisKey() == smaller.synthesisKey())
    #expect(try lossless.renderKey() != smaller.renderKey())
    #expect(try legacy.renderKey() == legacy.synthesisKey())
    struct OldContent: Encodable {
        let revision: String; let source: ChapterSourceIdentity; let recipe: ChapterRenderRecipe
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let oldBytes = try encoder.encode(OldContent(revision: ChapterRenderRequest.revision, source: legacy.source, recipe: legacy.recipe))
    let oldKey = SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined()
    #expect(try legacy.renderKey() == oldKey)
    for value in [legacy, lossless, smaller] {
        let decoded = try JSONDecoder().decode(ChapterRenderRequest.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        #expect(try decoded.renderKey() == value.renderKey())
    }
    var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(smaller)) as? [String: Any])
    json["delivery"] = "unknown-codec"
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ChapterRenderRequest.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func manifest(_ r: ChapterRenderRequest, codec: String) throws -> ChapterArtifactManifest {
        .init(renderKey: try r.renderKey(), audioSHA256: String(repeating: "0", count: 64), audioByteCount: 8,
              decodedFrameCount: 240, codecRevision: codec, units: [
                .init(source: .init(offset: 0, length: 40), fragments: [.init(offset: 0, length: 40)], startFrame: 0, frameCount: 240)])
    }
    try manifest(lossless, codec: ChapterAudioDelivery.lossless.codecRevision).validate(for: lossless)
    try manifest(smaller, codec: ChapterAudioDelivery.smaller.codecRevision).validate(for: smaller)
    for (r, codec) in [(lossless, ChapterAudioDelivery.smaller.codecRevision),
                       (smaller, ChapterAudioDelivery.lossless.codecRevision),
                       (legacy, ChapterAudioDelivery.smaller.codecRevision),
                       (legacy, "aac-alias"), (legacy, "unknown-codec")] {
        #expect(throws: ChapterWorkerError.invalidManifest) { try manifest(r, codec: codec).validate(for: r) }
    }
}
