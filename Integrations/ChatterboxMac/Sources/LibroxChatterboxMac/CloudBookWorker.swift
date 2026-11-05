#if os(macOS)
import Foundation
import CloudKit
import Darwin
import LibroxChapterWorker
import LibroxChatterboxPlanning

private final class CloudWorkerOwnership: Sendable {
    let descriptor: Int32
    let workerID: UUID
    private let path: String
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        path = root.appendingPathComponent("worker.lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ChapterWorkerError.busy }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw ChapterWorkerError.busy }
        let file = root.appendingPathComponent("worker-id.txt")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                guard let id = UUID(uuidString: try String(contentsOf: file, encoding: .utf8)) else { throw ChapterWorkerError.invalidIdentity }
                workerID = id
            } else {
                workerID = UUID()
                try Data(workerID.uuidString.utf8).write(to: file, options: .withoutOverwriting)
            }
        } catch { Darwin.close(descriptor); throw error }
    }
    deinit { Darwin.close(descriptor) }
    func validate() throws {
        var info = stat(), current = stat()
        guard fstat(descriptor, &info) == 0, lstat(path, &current) == 0,
              info.st_mode & S_IFMT == S_IFREG, current.st_mode & S_IFMT == S_IFREG,
              info.st_dev == current.st_dev, info.st_ino == current.st_ino else { throw ChapterWorkerError.staleClaim }
    }
}

public struct ChatterboxCloudWorkerUpdate: Sendable {
    public enum Phase: String, Sendable { case loading, waiting, rendering, publishing, failed, stopped }
    public let phase: Phase
    public let bookTitle: String?
    public let chapterIndex: Int?
    public let totalChapters: Int
    public let publishedSegments: Int
    public let message: String?
    fileprivate init(_ phase: Phase, title: String? = nil, chapter: Int? = nil,
                     total: Int = 0, segments: Int = 0, message: String? = nil) {
        self.phase = phase; bookTitle = title; chapterIndex = chapter
        totalChapters = total; publishedSegments = segments; self.message = message
    }
}

/// One resident native renderer and one serial driver. Native output passes
/// verified custody, CKAsset upload and fenced head publication in that order.
public actor ChatterboxMacCloudBookWorker {
    private let connection: ChatterboxCloudBookConnection
    private let renderer: ChatterboxMacResidentRenderer
    private var ownership: CloudWorkerOwnership?
    private let workerID: UUID
    private let runID = UUID()
    private nonisolated let operations = ChatterboxCloudOperations()
    private var driver: Task<Void, Never>?
    private var closeTask: Task<Void, Error>?
    private var failed: Set<String> = []
    private let receive: @Sendable (ChatterboxCloudWorkerUpdate) async -> Void

    private init(connection: ChatterboxCloudBookConnection, renderer: ChatterboxMacResidentRenderer,
                 ownership: CloudWorkerOwnership, receive: @escaping @Sendable (ChatterboxCloudWorkerUpdate) async -> Void) {
        self.connection = connection; self.renderer = renderer; self.ownership = ownership
        workerID = ownership.workerID; self.receive = receive
    }
    public static func open(container: CKContainer, account: ChapterCloudAccountIdentity,
                            session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                            workerDirectory: URL, assets: ChatterboxMacModelAssets, storagePolicy: ChapterStorageBudgetPolicy,
                            authorizeTransfer: @escaping @Sendable () async throws -> Void,
                            receive: @escaping @Sendable (ChatterboxCloudWorkerUpdate) async -> Void) async throws -> Self {
        let task = Task.detached(priority: .utility) {
            try await gate.validate(session); try Task.checkCancellation()
            let owner = try CloudWorkerOwnership(root: workerDirectory)
            let connection = try ChatterboxCloudBookConnection(container: container, account: account,
                session: session, gate: gate, root: workerDirectory.appendingPathComponent("Storage"),
                policy: storagePolicy, authorize: authorizeTransfer, validateWorkerOwnership: { try owner.validate() })
            return Self(connection: connection, renderer: .init(assets: assets), ownership: owner, receive: receive)
        }
        let worker = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do { try Task.checkCancellation(); try await gate.validate(session); return worker }
        catch { try? await worker.close(); throw error }
    }
    public func start() throws {
        try operations.check(); guard driver == nil else { return }
        driver = Task { [weak self, operations, renderer, connection, receive] in
            guard let self else { return }
            do {
                try await operations.run {
                    await receive(.init(.loading))
                    _ = try await renderer.prepare()
                    let descriptor = try await renderer.stockVoiceDescriptor()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    try await connection.directory.prepareZone()
                    try await connection.directory.publishCatalog(encoder.encode(ChatterboxCloudStockRecord(descriptor)))
                    while !Task.isCancelled {
                        do {
                            let worked = try await self.tick()
                            if !worked {
                                await receive(.init(.waiting))
                                try await Task.sleep(for: .seconds(10))
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            try operations.check()
                            await receive(.init(.failed, message: error.localizedDescription))
                            try await Task.sleep(for: .seconds(30))
                        }
                    }
                }
            } catch {
                if !Task.isCancelled { await receive(.init(.failed, message: error.localizedDescription)) }
            }
            await self.driverExited()
        }
    }
    private func driverExited() { driver = nil }
    public func retryFailed() async throws {
        try operations.check()
        for scope in Set(failed.compactMap { $0.split(separator: ":").first.map(String.init) }) {
            try await connection.directory.reportFailure(nil, scopeID: scope)
        }
        failed.removeAll(); if driver == nil { try start() }
    }
    private func tick() async throws -> Bool {
        let c = connection
        try operations.check(); try await c.gate.validate(c.session)
        for listing in try await c.directory.books() {
            for set in try await c.currentSets(scopeID: listing.scopeID) {
                let prioritized = set.metadata.intent.priority.chapterIndex
                let entries = set.metadata.entries.sorted {
                    if $0.chapterIndex == prioritized { return true }
                    if $1.chapterIndex == prioritized { return false }
                    return $0.chapterIndex < $1.chapterIndex
                }
                for entry in entries where entry.kind == .chapter {
                    let key = "\(listing.scopeID):\(entry.chapterIndex):\(set.metadata.intent.deviceID):\(set.metadata.intent.revision)"
                    guard !failed.contains(key), let content = try await c.content(set, at: entry.chapterIndex),
                          case .chapter(let prepared) = content.entry else { continue }
                    let admission = try ChapterBookWorkAdmission(readSet: set.metadata,
                        request: prepared.submission.request, chapterIndex: entry.chapterIndex)
                    let existing = try await c.work.prefix(admission, through: nil, originalText: content.originalText)
                    if existing.seal != nil { continue }
                    do {
                        try await render(admission, prepared: prepared, existing: existing.manifests,
                            title: listing.title, total: set.book.scope.book.chapterKeys.count)
                        return true
                    } catch is CancellationError { throw CancellationError() }
                    catch ChapterWorkerError.staleClaim { throw ChapterWorkerError.staleClaim }
                    catch let error as ChapterDemandTransportError {
                        switch error {
                        case .offline, .uncertain, .conflict, .busy, .retryAfter: throw error
                        default:
                            failed.insert(key)
                            await receive(.init(.failed, title: listing.title, chapter: entry.chapterIndex,
                                total: set.book.scope.book.chapterKeys.count, message: error.localizedDescription))
                        }
                    }
                    catch {
                        failed.insert(key)
                        await receive(.init(.failed, title: listing.title, chapter: entry.chapterIndex,
                            total: set.book.scope.book.chapterKeys.count, message: error.localizedDescription))
                    }
                }
            }
        }
        return false
    }
    private func render(_ admission: ChapterBookWorkAdmission, prepared: ChatterboxPreparedChapterSubmission,
                        existing: [ChapterSegmentManifest], title: String, total: Int) async throws {
        let c = connection
        // Scope covers output PCM/cache plus verified copies and upload staging.
        // Admission is a logical bound; encoder/renderer retain their own guards.
        let allowance = try await c.budget.reserve(bytes: 4 * 1024 * 1024 * 1024)
        var token: ChapterBookCloudWorkToken?
        do {
            do { token = try await c.work.acquire(admission, workerID: workerID, runID: runID) }
            catch ChapterWorkerError.busy { token = try await c.work.resumeAfterJoin(admission, workerID: workerID, runID: runID) }
            catch ChapterWorkerError.invalidTransition { token = try await c.work.resumeAfterJoin(admission, workerID: workerID, runID: runID) }
            guard let token else { throw ChapterWorkerError.staleClaim }
            let binding = try await renderer.bindChapter(plan: prepared.plan, submission: prepared.submission, gate: c.gate)
            await receive(.init(.rendering, title: title, chapter: admission.chapterIndex, total: total, segments: existing.count))
            let seal = try await renderer.renderSegments(binding, gate: c.gate, outputDirectory: c.output,
                admission: { try await c.work.requireCurrent(token, admission: admission) },
                receive: { [receive] export in
                    if export.manifest.segmentIndex < existing.count {
                        // Deterministic replay can continue a partial prefix only
                        // when every prior complete file is byte-identical.
                        guard export.manifest == existing[export.manifest.segmentIndex] else { throw ChapterWorkerError.invalidManifest }
                        return
                    }
                    await receive(.init(.publishing, title: title, chapter: admission.chapterIndex,
                        total: total, segments: export.manifest.segmentIndex))
                    let artifact = try await ChapterLocalSegmentArtifact.adopt(download: export.audioFile,
                        manifest: export.manifest, request: prepared.submission.request,
                        originalText: prepared.submission.originalText, session: c.session, gate: c.gate, storageDirectory: c.custody)
                    let uploaded = try await c.segments.upload(artifact, originalText: prepared.submission.originalText)
                    try await c.work.append(export.manifest, content: uploaded, token: token, admission: admission,
                        originalText: prepared.submission.originalText)
                    _ = try await c.budget.observeWithinCapacity(allowance)
                    await receive(.init(.rendering, title: title, chapter: admission.chapterIndex,
                        total: total, segments: export.manifest.segmentIndex + 1))
                })
            try await c.work.seal(seal, token: token, admission: admission, originalText: prepared.submission.originalText)
            try await c.work.releaseAfterJoin(token)
            _ = try await c.budget.settleAfterJoining(allowance)
        } catch {
            // renderSegments owns and joins the encoder and upload callback.
            // After cancellation a claim may remain until this SAME locked
            // installation reconnects; another Mac can never steal it.
            if let token, !Task.isCancelled {
                try? await c.directory.reportFailure(error.localizedDescription, scopeID: admission.readSet.scope.identifier)
                try? await c.work.releaseAfterJoin(token)
            }
            try? await c.budget.releaseAfterJoining(allowance)
            throw error
        }
    }
    public nonisolated func stopClaims() { operations.stop() }
    public func close() async throws {
        if let closeTask { try await closeTask.value; return }
        operations.stop(); driver?.cancel()
        let pending = driver
        let task = Task { [operations, renderer, connection] in
            await pending?.value; await operations.join()
            await renderer.shutdown(); try await connection.budget.close()
        }
        closeTask = task; try await task.value
        ownership = nil; driver = nil
        await receive(.init(.stopped))
    }
}
#endif
