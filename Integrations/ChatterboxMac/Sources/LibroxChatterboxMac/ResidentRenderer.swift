#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import LibroxChatterbox
import LibroxChatterboxMLX
import LibroxChapterWorker
import LibroxChatterboxPlanning
import ChatterboxCoreML
import ChatterboxMacAcousticAudit
import KokoroNarration
import Synchronization

/// Cancellation must reach synchronous actor-owned load kernels without waiting
/// for that actor's mailbox. The registry owns no model and never releases one.
private final class ResidentCancellation: Sendable {
    private struct Entry: Sendable { var closed = false; var token: UUID?; var cancel: (@Sendable () -> Void)? }
    private let entry = Mutex(Entry())
    func register(_ cancel: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        let closed = entry.withLock { value -> Bool in
            if value.closed { return true }
            value.token = token; value.cancel = cancel; return false
        }
        if closed { cancel() }
        return token
    }
    func clear(_ token: UUID) { entry.withLock { if $0.token == token { $0.token = nil; $0.cancel = nil } } }
    func close() {
        let cancel = entry.withLock { value -> (@Sendable () -> Void)? in
            value.closed = true; return value.cancel
        }
        cancel?()
    }
}

public struct ChatterboxMacModelAssets: Sendable {
    public let metallib, acousticCheckpoint, decoderWeights, decoderOracle, frontendDirectory, stockConditioning: URL
    public init(metallib: URL, acousticCheckpoint: URL, decoderWeights: URL, decoderOracle: URL,
                frontendDirectory: URL, stockConditioning: URL) {
        self.metallib = metallib; self.acousticCheckpoint = acousticCheckpoint
        self.decoderWeights = decoderWeights; self.decoderOracle = decoderOracle
        self.frontendDirectory = frontendDirectory; self.stockConditioning = stockConditioning
    }
}

/// A local completed export, not a CloudKit asset, demand acknowledgement or distributed lease.
public struct ChatterboxMacChapterArtifact: Sendable {
    public let audioFile, receiptFile: URL
    public let receipt: Receipt
    /// Complete local warm work including receipt synchronization/publication.
    /// Does not include loading, CloudKit transfer, or host playback startup.
    public let completeWarmSeconds: Double
    public struct Receipt: Codable, Sendable {
        public struct Binding: Codable, Sendable {
            public let renderKey, accountPartition: String
            public let epoch: UUID
        }
        public let revision: String
        public let binding: Binding?
        public let sourceSHA256: String
        public let sourceUTF16Length: Int
        public let settingsSHA256, rendererProfile, pcmSHA256: String
        public let codecRevision: String
        public let export: NativeAudioExportReport
        public let units: [ChapterAudioUnit]
        /// Warm work through verified encoding/readback, before receipt publication; startup is separate.
        public let warmSecondsBeforeReceipt: Double
    }
}

// Internal seam permits orchestration tests without initializing MLX or claiming inference.
protocol ResidentChapterBackend: Sendable {
    var profile: String { get }
    var modelSHA256: String { get }
    var conditioningSHA256: String { get }
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL,
                receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws
}

/// Dedicated native worker process only; never initialize another MLX runtime first.
/// prepare() loads once; successful chapters keep the models resident. shutdown()
/// is terminal and cancels/joins owned work before releasing runtime/model handles.
public actor ChatterboxMacResidentRenderer {
    public enum State: Sendable, Equatable { case cold, loading, ready, rendering, closing, closed }
    public struct LoadingReport: Sendable { public let coldSeconds: Double; public let rendererProfile: String }
    private let assets: ChatterboxMacModelAssets?
    private let testFactory: (@Sendable () async throws -> any ResidentChapterBackend)?
    private var runtime: ChatterboxMacRuntime?
    private var acoustic: ChatterboxMacAcousticSynthesizer?
    private var backend: (any ResidentChapterBackend)?
    private var loading: Task<LoadingReport, Error>?
    private var rendering: Task<ChatterboxMacChapterArtifact, Error>?
    private var segmenting: Task<ChapterSegmentCompletionSeal, Error>?
    private var current: State = .cold
    private var loadReport: LoadingReport?
    private nonisolated let cancellation = ResidentCancellation()
    private let rendererID = UUID()

    public init(assets: ChatterboxMacModelAssets) { self.assets = assets; testFactory = nil }
    init(testFactory: @escaping @Sendable () async throws -> any ResidentChapterBackend) {
        assets = nil; self.testFactory = testFactory
    }
    public func state() -> State { current }
    /// Actual prepared backend identity, not an available/approved catalog entry.
    /// Reader-side canonical planning uses this value without importing MLX.
    public func stockVoiceDescriptor() throws -> ChatterboxStockVoiceDescriptor {
        guard current != .closing, current != .closed else { throw ChatterboxMacRendererError.closed }
        guard current == .ready, let backend else { throw ChatterboxMacRendererError.busy }
        return try .init(modelSHA256: backend.modelSHA256, conditioningSHA256: backend.conditioningSHA256, rendererProfile: backend.profile)
    }
    public func prepare() async throws -> LoadingReport {
        try Task.checkCancellation()
        guard current != .closing, current != .closed else { throw ChatterboxMacRendererError.closed }
        if current == .ready, let loadReport { return loadReport }
        guard current == .cold else { throw ChatterboxMacRendererError.busy }
        current = .loading
        let task = Task { try await self.loadOwned() }
        loading = task
        let token = cancellation.register { task.cancel() }
        defer { loading = nil; cancellation.clear(token) }
        do {
            let report = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard current == .loading else { throw CancellationError() }
            // State publication and loading-slot cleanup occur in this same
            // actor continuation, with no await between them.
            loadReport = report; current = .ready
            return report
        } catch {
            backend = nil; acoustic = nil; runtime = nil
            if current == .loading { current = .cold }
            throw error
        }
    }
    private func loadOwned() async throws -> LoadingReport {
        let began = Date()
        do {
            try Task.checkCancellation()
            let selected: any ResidentChapterBackend
            if let testFactory { selected = try await testFactory() }
            else {
                guard let assets, ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0" else { throw ChatterboxMacRendererError.unavailable }
                try StandardModelIdentity.verifyFrontend(assets.frontendDirectory)
                // This non-Sendable runtime remains exclusively actor-owned.
                runtime = try ChatterboxMacRuntime(metallib: assets.metallib)
                ChatterboxMLXRenderer.configureBufferCache(maximumBytes: 256 * 1024 * 1024)
                let native = try ChatterboxMacAcousticSynthesizer(checkpoint: assets.acousticCheckpoint,
                    metallib: assets.metallib, stockConditioning: assets.stockConditioning, waveformPolicy: .deterministicGather)
                acoustic = native
                let renderer = try await ChatterboxMLXRenderer(weightsFile: assets.decoderWeights,
                    oracleFile: assets.decoderOracle, modelDirectory: assets.frontendDirectory,
                    defaultVoice: assets.stockConditioning, watermarkDirectory: assets.frontendDirectory,
                    acousticComputeUnits: .init(encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly),
                    watermarkPolicy: .disabled, acousticBackend: try native.backend())
                try StandardModelIdentity.verifyFrontend(assets.frontendDirectory)
                selected = try NativeResidentBackend(renderer: renderer, voice: assets.stockConditioning,
                    modelSHA256: StandardModelIdentity.modelSHA256())
            }
            try Task.checkCancellation()
            guard current == .loading else { throw CancellationError() }
            let report = LoadingReport(coldSeconds: Date().timeIntervalSince(began), rendererProfile: selected.profile)
            backend = selected
            return report
        } catch {
            backend = nil; acoustic = nil; runtime = nil
            throw error
        }
    }
    public func renderChapter(_ request: ChatterboxMacChapterRequest, outputDirectory: URL) async throws -> ChatterboxMacChapterArtifact {
        try await startRender(request, outputDirectory: outputDirectory, authorization: nil)
    }
    /// Constructs the canonical service request from the actual resident backend;
    /// the host supplies only source identity, exact text/settings and its session.
    public func bindChapter(source: ChapterSourceIdentity, request: ChatterboxMacChapterRequest,
                            session: ChapterAccountSession, gate: ChapterAccountSessionGate) async throws -> ChatterboxMacChapterBinding {
        let authorization = MacChapterAuthorization(session: session, gate: gate)
        try await authorization.validate()
        guard current != .closing, current != .closed else { throw ChatterboxMacRendererError.closed }
        guard current == .ready, let backend else { throw ChatterboxMacRendererError.busy }
        return try ChatterboxMacChapterBinding(source: source, localRequest: request, rendererID: rendererID,
            backend: backend, session: session)
    }
    /// Restore all options, then recompute the request using this Worker's actual
    /// qualified backend. Matching hashes cannot be used to invent defaults.
    public func bindChapter(plan: ChatterboxMacRenderPlan, submission: ChapterSubmission,
                            gate: ChapterAccountSessionGate) async throws -> ChatterboxMacChapterBinding {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        let request = try plan.restore(source: submission.originalText)
        let binding = try await bindChapter(source: submission.request.source, request: request,
            session: submission.session, gate: gate)
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        guard binding.submission.request.accountPartition == submission.request.accountPartition,
              try binding.submission.request.renderKey() == submission.request.renderKey()
        else { throw ChatterboxMacRenderPlanError.recipeMismatch }
        return binding
    }
    public func renderChapter(_ binding: ChatterboxMacChapterBinding, gate: ChapterAccountSessionGate,
                              outputDirectory: URL) async throws -> ChatterboxMacChapterArtifact {
        guard binding.rendererID == rendererID else { throw ChapterWorkerError.invalidManifest }
        return try await startRender(binding.localRequest, outputDirectory: outputDirectory,
            authorization: MacChapterAuthorization(session: binding.submission.session, gate: gate,
                renderKey: binding.submission.request.renderKey()))
    }
    // Worker-only admission seam, checked at existing preparation/output boundaries.
    // No model arithmetic, sampler, guard or public unbound-render behavior changes.
    func renderChapter(_ binding: ChatterboxMacChapterBinding, gate: ChapterAccountSessionGate,
                       outputDirectory: URL, admission: @escaping @Sendable () async throws -> Void) async throws -> ChatterboxMacChapterArtifact {
        guard binding.rendererID == rendererID else { throw ChapterWorkerError.invalidManifest }
        return try await startRender(binding.localRequest, outputDirectory: outputDirectory,
            authorization: MacChapterAuthorization(session: binding.submission.session, gate: gate,
                renderKey: binding.submission.request.renderKey(), admission: admission))
    }
    /// Emits each complete, readback-verified passage file before the chapter
    /// finishes. Same globally planned backend stream/context/cadence as the
    /// chapter API; no per-segment replanning or second model. The receiver is
    /// awaited and owned by this operation. It must join any transport work.
    /// These exports are NOT cloud acknowledgements or Reader playback grants.
    public func renderSegments(_ binding: ChatterboxMacChapterBinding, gate: ChapterAccountSessionGate,
                               outputDirectory: URL,
                               admission: @escaping @Sendable () async throws -> Void = {},
                               receive: @escaping @Sendable (ChatterboxMacSegmentExport) async throws -> Void)
        async throws -> ChapterSegmentCompletionSeal {
        try Task.checkCancellation()
        guard binding.rendererID == rendererID else { throw ChapterWorkerError.invalidManifest }
        guard current != .closing, current != .closed else { throw ChatterboxMacRendererError.closed }
        guard current == .ready, let backend else { throw ChatterboxMacRendererError.busy }
        let authorization = try MacChapterAuthorization(session: binding.submission.session, gate: gate,
            renderKey: binding.submission.request.renderKey(), admission: admission)
        current = .rendering
        let task = Task {
            try await authorization.validate(); try Task.checkCancellation(); try self.runtime?.verify()
            let writer = try ResidentSegmentWriter(submission: binding.submission, directory: outputDirectory)
            try await backend.stream(binding.localRequest, cache: writer.cacheDirectory) { passage in
                try await authorization.validate()
                try await writer.append(passage) { export in
                    try await authorization.validate(); try Task.checkCancellation()
                    try await receive(export)
                    try await authorization.validate(); try Task.checkCancellation()
                }
            }
            try await authorization.validate(); try Task.checkCancellation(); try self.runtime?.verify()
            let seal = try await writer.finish()
            // Final asynchronous authority work remains in this exact owned
            // task. Shutdown must join it before releasing runtime resources.
            try await authorization.validate(); try Task.checkCancellation(); try self.runtime?.verify()
            return seal
        }
        segmenting = task
        let token = cancellation.register { task.cancel() }
        defer { segmenting = nil; cancellation.clear(token); if current == .rendering { current = .ready } }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await gate.validate(binding.submission.session); try Task.checkCancellation()
        guard current == .rendering else { throw CancellationError() }
        return result
    }
    private func startRender(_ request: ChatterboxMacChapterRequest, outputDirectory: URL,
                             authorization: MacChapterAuthorization?) async throws -> ChatterboxMacChapterArtifact {
        try Task.checkCancellation()
        guard current != .closing, current != .closed else { throw ChatterboxMacRendererError.closed }
        guard current == .ready, let backend else { throw ChatterboxMacRendererError.busy }
        current = .rendering
        let task = Task { try await self.renderOwned(request, backend: backend, outputDirectory: outputDirectory, authorization: authorization) }
        rendering = task
        let token = cancellation.register { task.cancel() }
        defer { rendering = nil; cancellation.clear(token); if current == .rendering { current = .ready } }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return result
    }
    private func renderOwned(_ request: ChatterboxMacChapterRequest, backend: any ResidentChapterBackend,
                             outputDirectory: URL, authorization: MacChapterAuthorization?) async throws -> ChatterboxMacChapterArtifact {
        let began = Date()
        try await authorization?.validate()
        try Task.checkCancellation(); try runtime?.verify()
        guard outputDirectory.isFileURL, !outputDirectory.path.utf8.contains(0) else { throw ChatterboxMacRendererError.storage }
        let values = try outputDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ChatterboxMacRendererError.storage }
        let job = outputDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let spool = try ChapterPCMSpool(source: request.text, directory: job)
        try await backend.stream(request, cache: job.appendingPathComponent("UnitCache")) { passage in
            try await authorization?.validate()
            try await spool.append(passage)
        }
        try await authorization?.validate()
        try Task.checkCancellation(); try runtime?.verify()
        let pcm = try await spool.finish()
        let file = job.appendingPathComponent("audio.m4a")
        // Owned detached codec work keeps the actor responsive to shutdown.
        // Cancellation propagates, and this await joins it even on failure.
        let exportTask = Task.detached(priority: .userInitiated) {
            try NativeFileAudioExport.write(rawPCM: pcm.file, frames: pcm.frames,
                pcmSHA256: pcm.pcmSHA256, to: file, codec: request.delivery == .smaller ? .aac64 : .alac24)
        }
        let exported = try await withTaskCancellationHandler { try await exportTask.value } onCancel: { exportTask.cancel() }
        try await authorization?.validate()
        try Task.checkCancellation(); try runtime?.verify()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bound = authorization.flatMap { a in a.renderKey.map {
            ChatterboxMacChapterArtifact.Receipt.Binding(renderKey: $0, accountPartition: a.session.accountPartition, epoch: a.session.epoch)
        } }
        let receipt = ChatterboxMacChapterArtifact.Receipt(revision: "mac-local-chapter-2", binding: bound,
            sourceSHA256: ChatterboxMacChapterRequest.hash(Data(request.text.utf8)), sourceUTF16Length: request.text.utf16.count,
            settingsSHA256: try request.deliveryIdentity(rendererProfile: backend.profile), rendererProfile: backend.profile,
            pcmSHA256: pcm.pcmSHA256, codecRevision: request.delivery.rawValue, export: exported, units: pcm.units,
            warmSecondsBeforeReceipt: Date().timeIntervalSince(began))
        let receiptFile = job.appendingPathComponent("complete.json")
        // Receipt is last: no partial source/PCM/audio stage is advertised as ready.
        let stagedReceipt = job.appendingPathComponent(".receipt-" + UUID().uuidString)
        let fd = Darwin.open(stagedReceipt.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ChatterboxMacRendererError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var receiptIdentity = stat()
        guard fstat(fd, &receiptIdentity) == 0 else { throw ChatterboxMacRendererError.storage }
        defer {
            var info = stat()
            if lstat(stagedReceipt.path, &info) == 0, info.st_dev == receiptIdentity.st_dev, info.st_ino == receiptIdentity.st_ino {
                unlink(stagedReceipt.path)
            }
        }
        let receiptBytes = try encoder.encode(receipt)
        guard receiptBytes.count <= ChatterboxMacWorkerStoragePolicy.maximumReceiptBytes else { throw ChatterboxMacRendererError.storage }
        try handle.write(contentsOf: receiptBytes); try handle.synchronize()
        guard fchmod(fd, 0o400) == 0 else { throw ChatterboxMacRendererError.storage }
        try handle.close()
        try await authorization?.validate()
        try Task.checkCancellation(); try runtime?.verify()
        guard link(stagedReceipt.path, receiptFile.path) == 0 else { throw ChatterboxMacRendererError.storage }
        let directoryFD = Darwin.open(job.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ChatterboxMacRendererError.storage }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw ChatterboxMacRendererError.storage }
        try await authorization?.validate()
        try Task.checkCancellation(); try runtime?.verify()
        return ChatterboxMacChapterArtifact(audioFile: file, receiptFile: receiptFile, receipt: receipt,
            completeWarmSeconds: Date().timeIntervalSince(began))
    }
    public nonisolated func shutdown() async {
        cancellation.close()
        await shutdownOwned()
    }
    private func shutdownOwned() async {
        if current == .closed { return }
        current = .closing
        let load = loading, render = rendering, segments = segmenting
        load?.cancel(); render?.cancel(); segments?.cancel()
        if let load { _ = try? await load.value }
        if let render { _ = try? await render.value }
        if let segments { _ = try? await segments.value }
        backend = nil; acoustic = nil; runtime = nil; loadReport = nil
        current = .closed
    }
}

private struct NativeResidentBackend: ResidentChapterBackend {
    let renderer: ChatterboxMLXRenderer
    let voice: URL
    let modelSHA256: String
    let conditioningSHA256 = ChatterboxMacAcousticSynthesizer.stockSHA256
    var profile: String { renderer.profileIdentifier }
    func stream(_ request: ChatterboxMacChapterRequest, cache: URL,
                receive: @escaping @Sendable (ChatterboxPreparedPassage) async throws -> Void) async throws {
        let endpoint = try await renderer.makeEndpoint(overlap: false)
        let manifest = ChatterboxMacChapterRequest.hash(Data((ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate.weightsSHA256 + AcousticInventory.checkpointSHA256 + "disabled-1").utf8))
        let session = try ChatterboxBookSession(narrator: endpoint.narrator, cacheDirectory: cache,
            modelManifestSHA256: manifest, rendererProfile: endpoint.profileIdentifier,
            maximumCacheBytes: ChatterboxMacWorkerStoragePolicy.maximumUnitCacheBytes)
        do {
            try await session.streamChapter(request.text, language: request.language, narratorID: "stock",
                conditioningFiles: ["stock": voice], conditioningSHA256: ["stock": ChatterboxMacAcousticSynthesizer.stockSHA256],
                direction: request.direction, grouping: request.grouping, seed: request.seed,
                performanceDirections: request.performanceDirections, receive: receive)
        } catch { try? await endpoint.narrator.unload(); throw error }
        try await endpoint.narrator.unload()
    }
}
#endif
