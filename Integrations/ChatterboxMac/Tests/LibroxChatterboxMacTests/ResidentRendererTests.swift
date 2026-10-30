#if os(macOS)
import XCTest
import Foundation
import CryptoKit
import LibroxChatterbox
import LibroxChapterWorker
@testable import ChatterboxCoreML
@testable import LibroxChatterboxMac

private actor ResidentTestGate {
    private var signalled: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var loads = 0
    func load() { loads += 1 }
    func nextLoad() -> Int { loads += 1; return loads }
    func wait(_ key: String) async {
        if !signalled.contains(key) { await withCheckedContinuation { waiters[key, default: []].append($0) } }
    }
    func signal(_ key: String) {
        signalled.insert(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
    }
}
private struct SyntheticResidentBackend: ResidentChapterBackend {
    let profile = "synthetic-no-inference-1"
    let modelSHA256 = String(repeating: "b", count: 64)
    let conditioningSHA256 = String(repeating: "c", count: 64) // Explicit synthetic identity, never a production stock hash.
    let voice: URL
    let gate: ResidentTestGate?
    let omitAudio: Bool
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL,
                receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        if let gate {
            await gate.signal("entered")
            await withTaskCancellationHandler { await gate.wait("release") } onCancel: { Task { await gate.signal("cancelled") } }
            try Task.checkCancellation()
        }
        if omitAudio { return }
        let narrator = ChatterboxNarrator(rendering: { _ in
            try ChatterboxAudioChunk(samples: (0..<2401).map { Float(sin(Double($0) * 0.05759)) * 0.3 })
        })
        let session = try ChatterboxBookSession(narrator: narrator, cacheDirectory: cache,
            modelManifestSHA256: String(repeating: "a", count: 64), rendererProfile: profile)
        try await session.streamChapter(request.text, language: request.language, narratorID: "stock",
            conditioningFiles: ["stock": voice], direction: request.direction, grouping: request.grouping,
            seed: request.seed, performanceDirections: request.performanceDirections, receive: receive)
        try await narrator.unload()
    }
}
private actor SegmentTestCollector {
    var values: [ChatterboxMacSegmentExport] = []
    func append(_ value: ChatterboxMacSegmentExport) -> Bool { values.append(value); return values.count == 1 }
}
final class ResidentRendererTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let voice = dir.appendingPathComponent("synthetic.safetensors")
        try Conditionals(speakerEmb: Array(repeating: 0, count: 256), condPromptSpeechTokens: [1],
            genEmbedding: Array(repeating: 0, count: 192), promptTokens: [1], promptFeat: Array(repeating: 0, count: 80)).write(to: voice)
        return (dir, voice)
    }
    func testResidentLoadedOnceAndCompleteLocalAACAndALACArtifacts() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let counter = ResidentTestGate()
        let renderer = ChatterboxMacResidentRenderer(testFactory: {
            await counter.load()
            return SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false)
        })
        _ = try await renderer.prepare(); _ = try await renderer.prepare()
        let loads = await counter.loads; XCTAssertEqual(loads, 1)
        let text = "Cafe\u{301} 🐈.\n\nShe said, “Keep going!” Then they left."
        let aac = try await renderer.renderChapter(.init(text: text, language: "en"), outputDirectory: dir)
        let alac = try await renderer.renderChapter(.init(text: text, language: "en", delivery: .lossless), outputDirectory: dir)
        XCTAssertEqual(aac.receipt.pcmSHA256, alac.receipt.pcmSHA256)
        XCTAssertNotEqual(aac.receipt.settingsSHA256, alac.receipt.settingsSHA256)
        XCTAssertEqual(aac.receipt.codecRevision, "aac-lc-64k-1"); XCTAssertEqual(alac.receipt.codecRevision, "alac24-1")
        for result in [aac, alac] {
            let receipt = try JSONDecoder().decode(ChatterboxMacChapterArtifact.Receipt.self, from: Data(contentsOf: result.receiptFile))
            XCTAssertEqual(receipt.sourceUTF16Length, text.utf16.count)
            XCTAssertEqual(receipt.sourceSHA256, ChatterboxMacChapterRequest.hash(Data(text.utf8)))
            XCTAssertEqual(receipt.units.last.map { $0.startFrame + $0.frameCount }, receipt.export.frames)
            XCTAssertTrue(receipt.export.frameCountMatches)
            XCTAssertEqual(receipt.rendererProfile, "synthetic-no-inference-1")
            XCTAssertGreaterThanOrEqual(result.completeWarmSeconds, receipt.warmSecondsBeforeReceipt)
        }
        let state = await renderer.state(); XCTAssertEqual(state, .ready)
        await renderer.shutdown()
        let closed = await renderer.state(); XCTAssertEqual(closed, .closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aac.audioFile.path))
    }
    func testSegmentsEmitBeforeChapterFinishesAndRetainExactPCMContextAndSourceMaps() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let text = "Cafe\u{301} 🐈 waited.\n\nShe said, “Keep going!”\n\nThen they left.\n"
        let options = try ChatterboxMacChapterRequest(text: text, language: "en", delivery: .lossless)
        let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:1",
            textSHA256: ChatterboxMacChapterRequest.hash(Data(text.utf8)), extractionRevision: "test-1", utf16Length: text.utf16.count)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let binding = try await renderer.bindChapter(source: source, request: options, session: session, gate: gate)
        let whole = try await renderer.renderChapter(binding, gate: gate, outputDirectory: dir)
        let collector = SegmentTestCollector(), progress = ResidentTestGate()
        let task = Task {
            try await renderer.renderSegments(binding, gate: gate, outputDirectory: dir) { value in
                if await collector.append(value) {
                    await progress.signal("first")
                    await progress.wait("continue")
                }
            }
        }
        await progress.wait("first")
        let active = await renderer.state(); XCTAssertEqual(active, .rendering)
        let observed = await collector.values
        let first = try XCTUnwrap(observed.first)
        let storage = dir.appendingPathComponent("reader-segments")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        let adopted = try await ChapterLocalSegmentArtifact.adopt(download: first.audioFile, manifest: first.manifest,
            request: binding.submission.request, originalText: text, session: session, gate: gate, storageDirectory: storage)
        XCTAssertEqual(adopted.manifest.segmentIndex, 0)
        let sealPath = first.audioFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("chapter-seal.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealPath.path))
        await progress.signal("continue")
        let seal = try await task.value, segments = await collector.values
        XCTAssertGreaterThan(segments.count, 1)
        var prefix = try ChapterSegmentPrefix(request: binding.submission.request, originalText: text), digest = SHA256()
        for segment in segments {
            try prefix.append(segment.manifest)
            let raw = try Data(contentsOf: segment.audioFile.deletingLastPathComponent().appendingPathComponent("chapter.f32"))
            digest.update(data: raw)
        }
        try prefix.validate(seal)
        XCTAssertEqual(digest.finalize().map { String(format: "%02x", $0) }.joined(), whole.receipt.pcmSHA256)
        XCTAssertEqual(seal.decodedFrameCount, whole.receipt.export.frames)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealPath.path))
        await renderer.shutdown()
    }
    func testSegmentShutdownJoinsBlockedReceiverAndDoesNotSealPartialChapter() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let text = "First sentence.\n\nSecond sentence.", options = try ChatterboxMacChapterRequest(text: text, language: "en")
        let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:1",
            textSHA256: ChatterboxMacChapterRequest.hash(Data(text.utf8)), extractionRevision: "test-1", utf16Length: text.utf16.count)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let binding = try await renderer.bindChapter(source: source, request: options, session: session, gate: gate)
        let progress = ResidentTestGate(), collector = SegmentTestCollector()
        let task = Task {
            try await renderer.renderSegments(binding, gate: gate, outputDirectory: dir) { value in
                _ = await collector.append(value); await progress.signal("first")
                await withTaskCancellationHandler { await progress.wait("release") } onCancel: {
                    Task { await progress.signal("cancelled") }
                }
                try Task.checkCancellation()
            }
        }
        await progress.wait("first")
        let stop = Task { await renderer.shutdown() }
        await progress.wait("cancelled")
        let closing = await renderer.state(); XCTAssertEqual(closing, .closing)
        await progress.signal("release"); await stop.value
        do { _ = try await task.value; XCTFail("Partial stream returned seal") } catch { XCTAssertTrue(error is CancellationError) }
        let observed = await collector.values
        let first = try XCTUnwrap(observed.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.audioFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.audioFile.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("chapter-seal.json").path))
        let closed = await renderer.state(); XCTAssertEqual(closed, .closed)
    }
    func testSegmentShutdownJoinsFinalAsynchronousAdmissionAfterSealWrite() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let text = "One sentence.", options = try ChatterboxMacChapterRequest(text: text, language: "en")
        let source = try ChapterSourceIdentity(bookSHA256: String(repeating: "b", count: 64), chapterKey: "spine:1",
            textSHA256: ChatterboxMacChapterRequest.hash(Data(text.utf8)), extractionRevision: "test-1", utf16Length: text.utf16.count)
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let binding = try await renderer.bindChapter(source: source, request: options, session: session, gate: gate)
        let progress = ResidentTestGate(), collector = SegmentTestCollector()
        let task = Task {
            try await renderer.renderSegments(binding, gate: gate, outputDirectory: dir, admission: {
                let values = await collector.values
                if let first = values.first,
                   FileManager.default.fileExists(atPath: first.audioFile.deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("chapter-seal.json").path) {
                    await progress.signal("final-admission")
                    await withTaskCancellationHandler { await progress.wait("release-final") } onCancel: {
                        Task { await progress.signal("final-cancelled") }
                    }
                    try Task.checkCancellation()
                }
            }, receive: { value in _ = await collector.append(value) })
        }
        await progress.wait("final-admission")
        let stop = Task { await renderer.shutdown() }
        await progress.wait("final-cancelled")
        let state = await renderer.state(); XCTAssertEqual(state, .closing)
        await progress.signal("release-final"); await stop.value
        do { _ = try await task.value; XCTFail("Cancelled final admission returned success") } catch { XCTAssertTrue(error is CancellationError) }
        let closed = await renderer.state(); XCTAssertEqual(closed, .closed)
    }
    func testShutdownCancelsAndJoinsBeforeClosedAndPreservesExistingFiles() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ResidentTestGate(), renderer = ChatterboxMacResidentRenderer(testFactory: {
            SyntheticResidentBackend(voice: voice, gate: gate, omitAudio: false)
        })
        _ = try await renderer.prepare()
        let request = try ChatterboxMacChapterRequest(text: "Keep going.", language: "en")
        let job = Task { try await renderer.renderChapter(request, outputDirectory: dir) }
        await gate.wait("entered")
        let shutdown = Task { await renderer.shutdown() }
        await gate.wait("cancelled")
        let closing = await renderer.state(); XCTAssertEqual(closing, .closing)
        do { _ = try await renderer.renderChapter(request, outputDirectory: dir); XCTFail("new claims must stop") } catch {}
        await gate.signal("release")
        await shutdown.value
        do { _ = try await job.value; XCTFail("cancelled work must not succeed") } catch { XCTAssertTrue(error is CancellationError) }
        let closed = await renderer.state(); XCTAssertEqual(closed, .closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: voice.path))
        let jobs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0 != voice }
        XCTAssertFalse(jobs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("complete.json").path) })
    }
    func testIncompleteStreamCannotPublishCompleteReceipt() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: true) })
        _ = try await renderer.prepare()
        do { _ = try await renderer.renderChapter(.init(text: "No missing words.", language: "en"), outputDirectory: dir); XCTFail("no empty completion") } catch {}
        let state = await renderer.state(); XCTAssertEqual(state, .ready)
        for job in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ $0 != voice }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.appendingPathComponent("complete.json").path))
        }
        await renderer.shutdown()
    }
    func testShutdownDuringLoadingCannotPublishReady() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ResidentTestGate()
        let renderer = ChatterboxMacResidentRenderer(testFactory: {
            await gate.signal("entered")
            await withTaskCancellationHandler { await gate.wait("release") } onCancel: { Task { await gate.signal("cancelled") } }
            return SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false)
        })
        let load = Task { try await renderer.prepare() }
        await gate.wait("entered")
        let shutdown = Task { await renderer.shutdown() }
        await gate.wait("cancelled")
        let state = await renderer.state(); XCTAssertEqual(state, .closing)
        await gate.signal("release"); await shutdown.value
        do { _ = try await load.value; XCTFail("cancelled load must not return ready") } catch { XCTAssertTrue(error is CancellationError) }
        let closed = await renderer.state(); XCTAssertEqual(closed, .closed)
        do { _ = try await renderer.prepare(); XCTFail("shutdown is terminal") } catch {}
    }
    func testCallerCancellationJoinsBeforeRendererBecomesReusable() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ResidentTestGate()
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: gate, omitAudio: false) })
        _ = try await renderer.prepare()
        let work = Task { try await renderer.renderChapter(.init(text: "Keep going.", language: "en"), outputDirectory: dir) }
        await gate.wait("entered"); work.cancel(); await gate.wait("cancelled")
        let running = await renderer.state(); XCTAssertEqual(running, .rendering)
        await gate.signal("release")
        do { _ = try await work.value; XCTFail("cancelled work must not succeed") } catch { XCTAssertTrue(error is CancellationError) }
        let ready = await renderer.state(); XCTAssertEqual(ready, .ready)
        await renderer.shutdown()
    }
    func testFailedLoadCleanupPrecedesExplicitRetryAndShutdownJoinsRetry() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ResidentTestGate()
        let renderer = ChatterboxMacResidentRenderer(testFactory: {
            if await gate.nextLoad() == 1 { throw ChatterboxMacRendererError.unavailable }
            await gate.signal("entered")
            await withTaskCancellationHandler { await gate.wait("release") } onCancel: { Task { await gate.signal("cancelled") } }
            return SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false)
        })
        do { _ = try await renderer.prepare(); XCTFail("first synthetic load fails") } catch { XCTAssertEqual(error as? ChatterboxMacRendererError, .unavailable) }
        let cold = await renderer.state(); XCTAssertEqual(cold, .cold)
        let retry = Task { try await renderer.prepare() }
        await gate.wait("entered")
        let shutdown = Task { await renderer.shutdown() }
        await gate.wait("cancelled")
        let closing = await renderer.state(); XCTAssertEqual(closing, .closing)
        await gate.signal("release"); await shutdown.value
        do { _ = try await retry.value; XCTFail("retry must be joined and cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let closed = await renderer.state(); XCTAssertEqual(closed, .closed)
    }
    func testCompleteLongChapterRetainsGlobalMapThroughEncodingAndReceipt() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let paragraph = "The morning was quiet, and the children waited by the open door. Nobody had forgotten the surprising letter that arrived the previous evening.\n\n"
        let text = String(repeating: paragraph, count: 250)
        XCTAssertGreaterThan(text.utf8.count, 32768)
        let result = try await renderer.renderChapter(.init(text: text, language: "en"), outputDirectory: dir)
        XCTAssertGreaterThan(result.receipt.units.count, 128)
        var frame: Int64 = 0, textEnd = 0
        let source = text as NSString
        for unit in result.receipt.units {
            XCTAssertEqual(unit.startFrame, frame)
            let gap = source.substring(with: NSRange(location: textEnd, length: unit.source.offset - textEnd))
            XCTAssertTrue(gap.allSatisfy(\.isWhitespace))
            frame += unit.frameCount; textEnd = unit.source.offset + unit.source.length
        }
        XCTAssertEqual(frame, result.receipt.export.frames)
        XCTAssertTrue(source.substring(from: textEnd).allSatisfy(\.isWhitespace))
        XCTAssertTrue(result.receipt.export.frameCountMatches)
        await renderer.shutdown()
    }
    private func source(_ text: String, key: String = "chapter-1") throws -> ChapterSourceIdentity {
        try ChapterSourceIdentity(bookSHA256: String(repeating: "d", count: 64), chapterKey: key,
            textSHA256: ChatterboxMacChapterRequest.hash(Data(text.utf8)), extractionRevision: "synthetic-extraction-1", utf16Length: text.utf16.count)
    }
    func testCanonicalBindingReturnsAccountBoundVerifiedPlaybackCustody() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let text = "Cafe\u{301} 🐈. Keep going!", request = try ChatterboxMacChapterRequest(text: text, language: "en")
        let binding = try await renderer.bindChapter(source: source(text), request: request, session: session, gate: gate)
        XCTAssertEqual(binding.submission.request.recipe.modelSHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(binding.submission.request.recipe.conditioningSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(binding.submission.request.recipe.rendererProfile, "synthetic-no-inference-1")
        let output = try await renderer.renderChapter(binding, gate: gate, outputDirectory: dir)
        let custody = dir.appendingPathComponent("private-custody")
        try FileManager.default.createDirectory(at: custody, withIntermediateDirectories: false)
        let artifact = try await binding.adopt(output, gate: gate, storageDirectory: custody)
        XCTAssertEqual(artifact.request, binding.submission.request); XCTAssertEqual(artifact.session, session)
        XCTAssertEqual(artifact.manifest.renderKey, try binding.submission.request.renderKey())
        XCTAssertEqual(artifact.decodedFrameCount, output.receipt.export.frames)
        let copy = try await artifact.withFileAccess(session: session, gate: gate) { $0 }
        XCTAssertNotEqual(copy, output.audioFile)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: output.audioFile))
        _ = try ChapterServiceUpdate(request: binding.submission.request, session: session, sequence: 1, state: .playable(artifact))
        await renderer.shutdown()
    }
    func testDeliverySeparatesRenderKeysWithoutChangingSynthesisRecipe() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let text = "Keep going!", identity = try source(text)
        let a = try await renderer.bindChapter(source: identity, request: .init(text: text, language: "en"), session: session, gate: gate)
        let b = try await renderer.bindChapter(source: identity, request: .init(text: text, language: "en", delivery: .lossless), session: session, gate: gate)
        XCTAssertEqual(a.submission.request.recipe, b.submission.request.recipe)
        XCTAssertEqual(try a.submission.request.synthesisKey(), try b.submission.request.synthesisKey())
        XCTAssertNotEqual(try a.submission.request.renderKey(), try b.submission.request.renderKey())
        let changed = try await renderer.bindChapter(source: identity, request: .init(text: text, language: "en", seed: 123), session: session, gate: gate)
        XCTAssertNotEqual(a.submission.request.recipe.synthesisOptionsSHA256, changed.submission.request.recipe.synthesisOptionsSHA256)
        await renderer.shutdown()
    }
    func testBridgeRejectsOtherChapterUnboundOutputAndStaleSession() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let text = "Keep going!", request = try ChatterboxMacChapterRequest(text: text, language: "en")
        let a = try await renderer.bindChapter(source: source(text), request: request, session: session, gate: gate)
        let b = try await renderer.bindChapter(source: source(text, key: "chapter-2"), request: request, session: session, gate: gate)
        let bound = try await renderer.renderChapter(a, gate: gate, outputDirectory: dir)
        let unbound = try await renderer.renderChapter(request, outputDirectory: dir)
        let storage = dir.appendingPathComponent("storage"); try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        for (binding, output) in [(b, bound), (a, unbound)] {
            do { _ = try await binding.adopt(output, gate: gate, storageDirectory: storage); XCTFail("mismatched binding must reject") }
            catch { XCTAssertEqual(error as? ChapterWorkerError, .invalidManifest) }
        }
        _ = try await gate.open(accountPartition: session.accountPartition)
        do { _ = try await a.adopt(bound, gate: gate, storageDirectory: storage); XCTFail("old epoch must reject") }
        catch { XCTAssertEqual(error as? ChapterWorkerError, .accountMismatch) }
        do { _ = try await renderer.renderChapter(a, gate: gate, outputDirectory: dir); XCTFail("stale render must reject") }
        catch { XCTAssertEqual(error as? ChapterWorkerError, .accountMismatch) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bound.audioFile.path))
        await renderer.shutdown()
    }
    func testBridgeRejectsTamperedEncodedFileAndKeepsOriginal() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) })
        _ = try await renderer.prepare()
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let text = "Keep going!"
        let binding = try await renderer.bindChapter(source: source(text), request: .init(text: text, language: "en"), session: session, gate: gate)
        let output = try await renderer.renderChapter(binding, gate: gate, outputDirectory: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.audioFile.path)
        var bytes = try Data(contentsOf: output.audioFile); bytes[bytes.count / 2] ^= 1; try bytes.write(to: output.audioFile)
        let storage = dir.appendingPathComponent("storage"); try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false)
        do { _ = try await binding.adopt(output, gate: gate, storageDirectory: storage); XCTFail("corruption must reject") }
        catch { XCTAssertEqual(error as? ChapterLocalArtifactError, .invalidFile) }
        XCTAssertEqual(try Data(contentsOf: output.audioFile), bytes)
        await renderer.shutdown()
    }
    func testPublicErrorsHaveStableNumericBridging() {
        let errors: [ChatterboxMacRendererError] = [.invalidSource, .invalidPassage, .sourceCoverage, .storage, .closed, .busy, .unavailable]
        for (index, error) in errors.enumerated() {
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "LibroxChatterboxMac.Renderer"); XCTAssertEqual(ns.code, index)
        }
    }
    func testFrontendAdmissionRejectsIncompleteOrUnexpectedTokenizerFilesWithoutMLX() throws {
        let (dir, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try StandardModelIdentity.verifyFrontend(dir)) {
            XCTAssertEqual($0 as? ChatterboxMacRendererError, .invalidSource)
        }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try StandardModelIdentity.verifyFrontend(dir)) {
            XCTAssertEqual($0 as? ChatterboxMacRendererError, .invalidSource)
        }
    }
    func testAccountChangeDuringRenderRejectsBeforePublication() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let control = ResidentTestGate()
        let renderer = ChatterboxMacResidentRenderer(testFactory: { SyntheticResidentBackend(voice: voice, gate: control, omitAudio: false) })
        _ = try await renderer.prepare()
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let text = "Keep going!"
        let binding = try await renderer.bindChapter(source: source(text), request: .init(text: text, language: "en"), session: session, gate: gate)
        let job = Task { try await renderer.renderChapter(binding, gate: gate, outputDirectory: dir) }
        await control.wait("entered"); await gate.close(); await control.signal("release")
        do { _ = try await job.value; XCTFail("revoked epoch must not publish") }
        catch { XCTAssertEqual(error as? ChapterWorkerError, .accountMismatch) }
        for child in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter({ $0 != voice }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("complete.json").path))
        }
        await renderer.shutdown()
    }
    func testBindingCannotBeRenderedByAnotherResidentInstance() async throws {
        let (dir, voice) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let factory: @Sendable () async throws -> any ResidentChapterBackend = { SyntheticResidentBackend(voice: voice, gate: nil, omitAudio: false) }
        let first = ChatterboxMacResidentRenderer(testFactory: factory), second = ChatterboxMacResidentRenderer(testFactory: factory)
        _ = try await first.prepare(); _ = try await second.prepare()
        let gate = ChapterAccountSessionGate(), session = try await gate.open(accountPartition: String(repeating: "a", count: 64))
        let text = "Keep going!"
        let binding = try await first.bindChapter(source: source(text), request: .init(text: text, language: "en"), session: session, gate: gate)
        do { _ = try await second.renderChapter(binding, gate: gate, outputDirectory: dir); XCTFail("wrong resident instance must reject") }
        catch { XCTAssertEqual(error as? ChapterWorkerError, .invalidManifest) }
        await first.shutdown(); await second.shutdown()
    }
}
#endif
