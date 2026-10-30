import Foundation
import Testing
import CryptoKit
import AVFoundation
import AudioToolbox
import Darwin
@testable import LibroxChapterWorker

private actor HandoffGate {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, release: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; entry?.resume(); entry = nil
        if !released { await withCheckedContinuation { release = $0 } }
    }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; release?.resume(); release = nil }
}
private final class HandoffFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-" + UUID().uuidString)
    let published: URL, worker: URL, reader: URL, incoming: URL
    let producerGate = ChapterAccountSessionGate(), receiverGate = ChapterAccountSessionGate()
    let text = " A🙂B \n"
    init(aac: Bool = false) throws {
        published = root.appendingPathComponent("Worker-Published"); worker = root.appendingPathComponent("Worker-Custody")
        reader = root.appendingPathComponent("Reader-Custody"); incoming = root.appendingPathComponent(aac ? "original.m4a" : "original.wav")
        for dir in [root, published, worker, reader] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144001)!
        buffer.frameLength = 144001
        for i in 0..<144001 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        try autoreleasepool {
            let settings: [String: Any] = aac ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000] : format.settings
            let file = try AVAudioFile(forWriting: incoming, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func create(aac: Bool = false, incomplete: Bool = false) async throws -> (ChapterLocalArtifact, ChapterSubmission) {
        let session = try await producerGate.open(accountPartition: String(repeating: "a", count: 64))
        let request = try ChapterRenderRequest(accountPartition: session.accountPartition, source: .init(
            bookSHA256: String(repeating: "b", count: 64), chapterKey: "chapter:1", textSHA256: hash(Data(text.utf8)),
            extractionRevision: "synthetic-1", utf16Length: text.utf16.count), recipe: .init(
                language: "en", stockVoiceID: "synthetic", conditioningSHA256: String(repeating: "c", count: 64),
                modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic-no-model", plannerRevision: "chapter-1",
                expressionSHA256: String(repeating: "e", count: 64), synthesisOptionsSHA256: String(repeating: "f", count: 64),
                seedPolicy: "fixed-1", watermarkRevision: "disabled-1"), delivery: aac ? .smaller : nil)
        let bytes = try Data(contentsOf: incoming), span = ChapterTextRange(offset: 1, length: incomplete ? 1 : 4)
        let manifest = ChapterArtifactManifest(renderKey: try request.renderKey(), audioSHA256: hash(bytes), audioByteCount: Int64(bytes.count),
            decodedFrameCount: 144001, codecRevision: aac ? "aac-lc-64k-1" : "wav-f32-1",
            units: [.init(source: span, fragments: [span], startFrame: 0, frameCount: 144001)])
        let artifact = try await ChapterLocalArtifact.adopt(download: incoming, request: request, manifest: manifest,
            originalText: text, session: session, gate: producerGate, storageDirectory: worker)
        return (artifact, try ChapterSubmission(request: request, originalText: text, session: session))
    }
    func receiver(_ request: ChapterRenderRequest) async throws -> ChapterSubmission {
        let session = try await receiverGate.open(accountPartition: request.accountPartition)
        return try .init(request: request, originalText: text, session: session)
    }
    func bundle(_ reference: ChapterLocalHandoffReference) -> URL { published.appendingPathComponent(reference.identifier) }
    func children(_ dir: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

@Suite(.serialized) struct ChapterLocalHandoffTests {
    @Test func newReceiverEpochAdoptsImmutablePublishedCopyForWAVAndAAC() async throws {
        for aac in [false, true] {
            let f = try HandoffFixture(aac: aac), (artifact, producer) = try await f.create(aac: aac)
            let predicted = try ChapterLocalHandoff.contentReference(for: artifact, submission: producer)
            let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
            #expect(reference == predicted)
            let receiver = try await f.receiver(producer.request)
            #expect(receiver.session.epoch != producer.session.epoch)
            let result = try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate,
                directory: f.published, storageDirectory: f.reader)
            #expect(result.session == receiver.session && result.request == producer.request)
            #expect(result.decodedFrameCount == 144001)
            let copied = try await result.withFileAccess(session: receiver.session, gate: f.receiverGate) { $0 }
            #expect(copied.path.hasPrefix(f.reader.path))
            #expect(try Data(contentsOf: copied) == Data(contentsOf: f.incoming))
            #expect(try f.children(f.published).count == 1)
        }
    }
    @Test func repeatPublicationReconcilesWithoutReplacingCompleteBundle() async throws {
        let f = try HandoffFixture(), (artifact, submission) = try await f.create()
        let a = try await ChapterLocalHandoff.publish(artifact, submission: submission, gate: f.producerGate, directory: f.published)
        let original = try Data(contentsOf: f.bundle(a).appendingPathComponent("receipt.json"))
        let b = try await ChapterLocalHandoff.publish(artifact, submission: submission, gate: f.producerGate, directory: f.published)
        #expect(a == b)
        #expect(try f.children(f.published).count == 1)
        #expect(try Data(contentsOf: f.bundle(a).appendingPathComponent("receipt.json")) == original)
    }
    @Test func noSharedEpochOrWrongRequestCanAuthorizeReceiver() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        let receiver = try await f.receiver(producer.request)
        await f.receiverGate.close()
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate, directory: f.published, storageDirectory: f.reader)
        }
        let session = try await f.receiverGate.open(accountPartition: producer.request.accountPartition)
        let old = producer.request.source
        let source = try ChapterSourceIdentity(bookSHA256: old.bookSHA256, chapterKey: "another-chapter", textSHA256: old.textSHA256,
            extractionRevision: old.extractionRevision, utf16Length: old.utf16Length)
        let other = try ChapterRenderRequest(accountPartition: session.accountPartition, source: source, recipe: producer.request.recipe)
        let wrong = try ChapterSubmission(request: other, originalText: f.text, session: session)
        await #expect(throws: ChapterLocalHandoffError.invalidRecord) {
            try await ChapterLocalHandoff.receive(reference, submission: wrong, gate: f.receiverGate, directory: f.published, storageDirectory: f.reader)
        }
        #expect(try f.children(f.reader).isEmpty)
    }
    @Test func incompleteSourceMapCannotBePublished() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create(incomplete: true)
        await #expect(throws: ChapterWorkerError.invalidManifest) {
            try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        }
        #expect(try f.children(f.published).isEmpty)
    }
    @Test func cancellationJoinsAndPreservesUnknownStagingEntries() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create(), pause = HandoffGate()
        let work = Task {
            try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published) { event in
                if case .beforeCommit = event { await pause.pause() }
            }
        }
        await pause.wait()
        let stage = try #require(f.children(f.published).first)
        try Data("keep".utf8).write(to: stage.appendingPathComponent("unknown"))
        work.cancel(); await pause.open()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(try f.children(stage).map(\.lastPathComponent) == ["unknown"])
        #expect(FileManager.default.fileExists(atPath: f.incoming.path))
    }
    @Test func lostAcknowledgementPreservesCompletePublicationForFreshReader() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let reference = try ChapterLocalHandoff.contentReference(for: artifact, submission: producer)
        await #expect(throws: CancellationError.self) {
            try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published) { event in
                if case .afterCommit = event { throw CancellationError() }
            }
        }
        #expect(try f.children(f.bundle(reference)).count == 2)
        let receiver = try await f.receiver(producer.request)
        let result = try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate,
            directory: f.published, storageDirectory: f.reader)
        #expect(result.session == receiver.session)
    }
    @Test func revokedReceiverAfterAdoptionReturnsNoHandleAndKeepsPublication() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        let receiver = try await f.receiver(producer.request)
        await #expect(throws: ChapterWorkerError.accountMismatch) {
            try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate,
                directory: f.published, storageDirectory: f.reader) { event in
                    if case .afterAdoption = event { await f.receiverGate.close() }
                }
        }
        #expect(try f.children(f.reader).isEmpty)
        #expect(try f.children(f.bundle(reference)).count == 2)
    }
    @Test func tamperedAudioAndSymlinkMetadataFailClosedWithoutRepair() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        let audio = f.bundle(reference).appendingPathComponent("audio")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
        var bytes = try Data(contentsOf: audio); bytes[bytes.count / 2] ^= 1; try bytes.write(to: audio)
        let receiver = try await f.receiver(producer.request)
        await #expect(throws: ChapterLocalArtifactError.invalidFile) {
            try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate, directory: f.published, storageDirectory: f.reader)
        }
        await #expect(throws: ChapterLocalHandoffError.invalidRecord) {
            try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        }
        #expect(try Data(contentsOf: audio) == bytes)
        let receipt = f.bundle(reference).appendingPathComponent("receipt.json")
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: f.incoming)
        await #expect(throws: ChapterLocalHandoffError.invalidRecord) {
            try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate, directory: f.published, storageDirectory: f.reader)
        }
    }
    @Test func referencesArePathSafeEvenWhenDecoded() throws {
        for id in ["../audio", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            #expect(throws: ChapterLocalHandoffError.invalidReference) { try ChapterLocalHandoffReference(identifier: id) }
            let data = try JSONSerialization.data(withJSONObject: ["identifier": id])
            #expect(throws: ChapterLocalHandoffError.invalidReference) { try JSONDecoder().decode(ChapterLocalHandoffReference.self, from: data) }
        }
    }
    @Test func readerCannotUsePublishedDirectoryAsMutableCustody() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        let receiver = try await f.receiver(producer.request)
        await #expect(throws: ChapterLocalHandoffError.storage) {
            try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate,
                directory: f.published, storageDirectory: f.published)
        }
        let unsafe = try await artifact.withFileAccess(session: producer.session, gate: f.producerGate) { $0.deletingLastPathComponent() }
        await #expect(throws: ChapterLocalHandoffError.storage) {
            try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: unsafe)
        }
        #expect(try f.children(unsafe).count == 1)
        #expect(try f.children(f.published).count == 1)
    }
    @Test func replacedBundleDirectoryIsRejectedAcrossReceiverAwait() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        let receiver = try await f.receiver(producer.request), original = f.bundle(reference), moved = f.published.appendingPathComponent("preserved-moved")
        await #expect(throws: ChapterLocalHandoffError.storage) {
            try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate,
                directory: f.published, storageDirectory: f.reader) { event in
                    if case .beforeAdoption = event {
                        try FileManager.default.moveItem(at: original, to: moved)
                        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
                    }
                }
        }
        #expect(try f.children(f.reader).isEmpty)
        #expect(try f.children(moved).count == 2)
    }
    @Test func completeValidationRejectsSplitGraphemesWithoutChangingRangeOnlyValidation() throws {
        let f = try HandoffFixture(), text = "e\u{301}"
        let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "b", count: 64), chapterKey: "nfd", textSHA256:
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), extractionRevision: "synthetic-1", utf16Length: 2)
        let recipe = try ChapterRenderRecipe(language: "en", stockVoiceID: "synthetic", conditioningSHA256: String(repeating: "c", count: 64),
            modelSHA256: String(repeating: "d", count: 64), rendererProfile: "synthetic", plannerRevision: "p", expressionSHA256: String(repeating: "e", count: 64),
            synthesisOptionsSHA256: String(repeating: "f", count: 64), seedPolicy: "fixed", watermarkRevision: "disabled-1")
        let request = try ChapterRenderRequest(accountPartition: String(repeating: "a", count: 64), source: source, recipe: recipe)
        let manifest = ChapterArtifactManifest(renderKey: try request.renderKey(), audioSHA256: String(repeating: "0", count: 64),
            audioByteCount: 64, decodedFrameCount: 2, codecRevision: "wav-f32-1", units: (0..<2).map {
                .init(source: .init(offset: $0, length: 1), fragments: [.init(offset: $0, length: 1)], startFrame: Int64($0), frameCount: 1)
            })
        try manifest.validateSourceMap(text: text, for: request)
        #expect(throws: ChapterWorkerError.invalidManifest) { try manifest.validateCompleteSourceMap(text: text, for: request) }
        #expect(FileManager.default.fileExists(atPath: f.incoming.path))
    }
    @Test func ancestorSymlinkCannotHideReaderCustodyInsidePublishedRoot() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        let nested = f.published.appendingPathComponent("nested-reader"), alias = f.root.appendingPathComponent("published-alias")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.published)
        let receiver = try await f.receiver(producer.request)
        await #expect(throws: ChapterLocalHandoffError.storage) {
            try await ChapterLocalHandoff.receive(reference, submission: receiver, gate: f.receiverGate,
                directory: f.published, storageDirectory: alias.appendingPathComponent("nested-reader"))
        }
        #expect(try f.children(nested).isEmpty)
    }
    @Test func ancestorSymlinkCannotHidePublicationInsideEphemeralSourceCustody() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create()
        let custody = try await artifact.withFileAccess(session: producer.session, gate: f.producerGate) { $0.deletingLastPathComponent() }
        let nested = custody.appendingPathComponent("published"), alias = f.root.appendingPathComponent("source-alias")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: custody)
        await #expect(throws: ChapterLocalHandoffError.storage) {
            try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate,
                directory: alias.appendingPathComponent("published"))
        }
        #expect(try f.children(nested).isEmpty)
    }
    @Test func retainedReferenceReopensThenRequiresFreshReceiverAdoption() async throws {
        let f = try HandoffFixture(), (artifact, producer) = try await f.create(), device = UUID()
        let reference = try await ChapterLocalHandoff.publish(artifact, submission: producer, gate: f.producerGate, directory: f.published)
        let journalRoot = f.root.appendingPathComponent("Reader-Outbox")
        try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: false)
        let store = try ChapterDemandOutbox(directory: journalRoot, accountPartition: producer.request.accountPartition, deviceID: device)
        let intent = try await store.setDemand(true, for: producer.request)
        #expect(try await store.rememberHandoff(reference, for: intent)); await store.close()
        let reopened = try ChapterDemandOutbox(directory: journalRoot, accountPartition: producer.request.accountPartition, deviceID: device)
        let saved = try await #require(reopened.retainedHandoff(for: producer.request))
        #expect(try await reopened.confirmation(for: producer.request) == nil)
        let receiver = try await f.receiver(producer.request)
        let adopted = try await ChapterLocalHandoff.receive(saved.reference, submission: receiver, gate: f.receiverGate,
            directory: f.published, storageDirectory: f.reader)
        #expect(adopted.session == receiver.session)
        #expect(adopted.session.epoch != producer.session.epoch)
        #expect(try await reopened.pending() == [intent])
        await reopened.close()
    }
}
