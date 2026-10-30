import Foundation
import Testing
import CryptoKit
@testable import LibroxChapterWorker

private func serviceRequest(watermark: String = "disabled-1") throws -> ChapterRenderRequest {
    let text = "A🙂B"
    return try .init(accountPartition: String(repeating: "a", count: 64), source: .init(
        bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:0",
        textSHA256: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
        extractionRevision: "test-reader-1", utf16Length: text.utf16.count), recipe: .init(
            language: "en", stockVoiceID: "test-stock", conditioningSHA256: String(repeating: "c", count: 64),
            modelSHA256: String(repeating: "d", count: 64), rendererProfile: "test-only", plannerRevision: "test-1",
            expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
            seedPolicy: "fixed-1", watermarkRevision: watermark))
}
private func serviceSession() -> ChapterAccountSession {
    .init(accountPartition: String(repeating: "a", count: 64), epoch: UUID())
}

@Suite struct ChapterServiceContractTests {
    @Test func submissionBindsExactTextAccountAndUnmarkedPolicy() throws {
        let request = try serviceRequest(), session = serviceSession()
        _ = try ChapterSubmission(request: request, originalText: "A🙂B", session: session)
        #expect(throws: ChapterWorkerError.invalidIdentity) {
            try ChapterSubmission(request: request, originalText: "A B", session: session)
        }
        #expect(throws: ChapterWorkerError.accountMismatch) {
            try ChapterSubmission(request: request, originalText: "A🙂B", session: .init(accountPartition: String(repeating: "b", count: 64), epoch: UUID()))
        }
        #expect(throws: ChapterServiceError.unsupportedPolicy) {
            try ChapterSubmission(request: serviceRequest(watermark: "perth-1"), originalText: "A🙂B", session: session)
        }
    }
    @Test func measuredProgressRejectsInvalidCountsAndMixedUnits() throws {
        for (completed, total): (Int64, Int64) in [(-1, 1), (2, 1), (0, 0), (0, .max)] {
            #expect(throws: ChapterServiceError.invalidProgress) {
                try ChapterMeasuredProgress(completed: completed, total: total, unit: .renderedUnits)
            }
        }
        let bytes = try ChapterMeasuredProgress(completed: 1, total: 100, unit: .downloadedBytes)
        let units = try ChapterMeasuredProgress(completed: 0, total: 3, unit: .renderedUnits)
        #expect(throws: ChapterServiceError.invalidProgress) {
            try ChapterServiceUpdate(request: serviceRequest(), session: serviceSession(), sequence: 1, state: .rendering(bytes))
        }
        #expect(throws: ChapterServiceError.invalidProgress) {
            try ChapterServiceUpdate(request: serviceRequest(), session: serviceSession(), sequence: 1, state: .downloading(units))
        }
    }
    @Test func catalogSeparatesAvailabilityFromListeningApproval() throws {
        let recipe = try serviceRequest().recipe
        let pending = try ChapterStockCapability(id: "test-en", displayName: "Test Voice", recipe: recipe,
            maximumSourceUTF16Length: 1000, availability: .available, listeningApproval: .pending)
        #expect(pending.maximumSourceUTF16Length == 1000)
        for limit in [0, 10_000_001] {
            #expect(throws: ChapterServiceError.invalidCatalog) {
                try ChapterStockCapability(id: "bad-limit", displayName: "Test", recipe: recipe,
                    maximumSourceUTF16Length: limit, availability: .available, listeningApproval: .pending)
            }
        }
        let catalog = try ChapterStockCatalog(session: serviceSession(), capabilities: [pending])
        #expect(catalog.capabilities[0].availability == .available)
        #expect(catalog.capabilities[0].listeningApproval == .pending)
        #expect(throws: ChapterServiceError.invalidCatalog) { try ChapterStockCatalog(session: serviceSession(), capabilities: [pending, pending]) }
        #expect(throws: ChapterServiceError.invalidCatalog) {
            try ChapterStockCapability(id: " ", displayName: "Test", recipe: recipe, maximumSourceUTF16Length: 1000, availability: .available, listeningApproval: .approved)
        }
        #expect(throws: ChapterServiceError.unsupportedPolicy) {
            try ChapterStockCapability(id: "marked", displayName: "Test", recipe: serviceRequest(watermark: "perth-1").recipe,
                maximumSourceUTF16Length: 1000, availability: .available, listeningApproval: .approved)
        }
    }
    @Test func receiptCannotConfuseLocalIntentWithRemoteAcknowledgement() throws {
        let request = try serviceRequest(), session = serviceSession(), device = UUID()
        let local = try ChapterDemandReceipt(request: request, session: session, deviceID: device,
                                            intentRevision: 1, wanted: true, delivery: .localIntent)
        #expect(local.delivery == .localIntent)
        #expect(throws: ChapterServiceError.invalidReceipt) {
            try ChapterDemandReceipt(request: request, session: session, deviceID: device,
                                     intentRevision: 0, wanted: true, delivery: .submitted)
        }
        #expect(throws: ChapterServiceError.invalidReceipt) {
            try ChapterDemandReceipt(request: request, session: session, deviceID: device,
                                     intentRevision: 1, wanted: true, delivery: .acknowledged(serverRevision: .init(opaqueValue: "")))
        }
        let ack = try ChapterDemandReceipt(request: request, session: session, deviceID: device,
            intentRevision: 1, wanted: false, delivery: .acknowledged(serverRevision: .init(opaqueValue: "test-only-tag")))
        #expect(!ack.wanted)
        #expect(throws: ChapterServiceError.invalidReceipt) { try ChapterServerRevision(opaqueValue: String(repeating: "x", count: 1025)) }
    }
    @Test func updateRejectsMalformedIdentitySequenceAndRemoteManifest() throws {
        let request = try serviceRequest(), session = serviceSession()
        #expect(throws: ChapterServiceError.invalidUpdate) {
            try ChapterServiceUpdate(request: request, session: session, sequence: 0, state: .queued)
        }
        let manifest = ChapterArtifactManifest(renderKey: String(repeating: "0", count: 64),
            audioSHA256: String(repeating: "c", count: 64), audioByteCount: 100, decodedFrameCount: 4,
            codecRevision: "wav-f32-1", units: [.init(source: .init(offset: 0, length: 4),
                fragments: [.init(offset: 0, length: 4)], startFrame: 0, frameCount: 4)])
        #expect(throws: ChapterWorkerError.invalidManifest) {
            try ChapterServiceUpdate(request: request, session: session, sequence: 1, state: .remoteReady(manifest))
        }
    }
    @Test func playableRequiresAdoptedArtifactAndExactEpoch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("incoming.wav")
        var data = Data()
        func bytes<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); bytes(UInt32(52)); data.append(Data("WAVEfmt ".utf8)); bytes(UInt32(16))
        bytes(UInt16(3)); bytes(UInt16(1)); bytes(UInt32(24_000)); bytes(UInt32(96_000)); bytes(UInt16(4)); bytes(UInt16(32))
        data.append(Data("data".utf8)); bytes(UInt32(16)); for _ in 0..<4 { bytes(Float(0.25).bitPattern) }
        try data.write(to: url)
        let request = try serviceRequest(), gate = ChapterAccountSessionGate()
        let session = try await gate.open(accountPartition: request.accountPartition)
        let span = ChapterTextRange(offset: 0, length: 4)
        let manifest = ChapterArtifactManifest(renderKey: try request.renderKey(),
            audioSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            audioByteCount: Int64(data.count), decodedFrameCount: 4, codecRevision: "wav-f32-1",
            units: [.init(source: span, fragments: [span], startFrame: 0, frameCount: 4)])
        let artifact = try await ChapterLocalArtifact.adopt(download: url, request: request, manifest: manifest,
            originalText: "A🙂B", session: session, gate: gate, storageDirectory: root)
        _ = try ChapterServiceUpdate(request: request, session: session, sequence: 1, state: .playable(artifact))
        #expect(throws: ChapterServiceError.invalidUpdate) {
            try ChapterServiceUpdate(request: request, session: serviceSession(), sequence: 2, state: .playable(artifact))
        }
        await gate.close()
        // A structurally valid update is not authorization: consumers recheck the gate.
        await #expect(throws: ChapterWorkerError.accountMismatch) { try await gate.validate(session) }
    }
    @Test func explicitFakeDemonstratesBoundedSnapshotAndCancellationContract() async throws {
        let fake = ContractStreamFake(), request = try serviceRequest(), session = serviceSession()
        let stream = try await fake.updates(for: request, session: session)
        for sequence in 1...100 {
            await fake.emit(try .init(request: request, session: session, sequence: UInt64(sequence), state: .queued))
        }
        var iterator = stream.makeAsyncIterator()
        let latest = try await iterator.next()
        #expect(latest?.sequence == 100)
        let consumer = Task { for try await _ in stream { } }
        consumer.cancel()
        _ = try? await consumer.value
        #expect(try await fake.waitForTermination())
    }
}

/// Test-only transport substitute. This proves protocol usage and standard stream
/// cancellation, not production CloudKit delivery or a production implementation.
private actor ContractStreamFake: ChapterService {
    private var continuation: AsyncThrowingStream<ChapterServiceUpdate, Error>.Continuation?
    private(set) var terminated = false
    func catalog(session: ChapterAccountSession) async throws -> ChapterStockCatalog { throw ChapterWorkerError.disabled }
    func submit(_ submission: ChapterSubmission) async throws -> ChapterDemandReceipt { throw ChapterWorkerError.disabled }
    func cancel(request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChapterDemandReceipt { throw ChapterWorkerError.disabled }
    func download(_ submission: ChapterSubmission) async throws -> ChapterLocalArtifact { throw ChapterWorkerError.disabled }
    func close(session: ChapterAccountSession) async throws { continuation?.finish(); continuation = nil }
    func updates(for request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> AsyncThrowingStream<ChapterServiceUpdate, Error> {
        let pair = AsyncThrowingStream<ChapterServiceUpdate, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.didTerminate() } }
        return pair.stream
    }
    func emit(_ update: ChapterServiceUpdate) { continuation?.yield(update) }
    func didTerminate() { terminated = true }
    func waitForTermination() async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !terminated, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return terminated
    }
}
