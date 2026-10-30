import Foundation
import LibroxChapterWorker
import LibroxChatterbox

/// Exact lazy Reader extraction; never navigate the Reader to produce it.
/// The provider owns verification that these bytes belong to its original book.
public struct ChatterboxBookTextInput: Sendable {
    public let text: String
    public let performanceDirections: ChatterboxPerformanceDirections?
    public init(text: String, performanceDirections: ChatterboxPerformanceDirections? = nil) throws {
        guard text.utf16.count <= 131072, text.utf8.count <= 393216 else { throw ChatterboxChapterRenderPlanError.budget }
        self.text = text; self.performanceDirections = performanceDirections
    }
}
public protocol ChatterboxBookSourceProvider: Sendable {
    var book: ChapterBookSource { get }
    /// Recheck the immutable original book binding before/after extraction and
    /// cooperate with cancellation. SDK owns ordering, publication and joins.
    func chapter(at originalSpineIndex: Int) async throws -> ChatterboxBookTextInput
}

/// Metadata only; no global phase can acknowledge this device's wanted intent.
public struct ChatterboxBookDemandReceipt: Sendable {
    public let session: ChapterAccountSession
    public let localIntent: ChapterBookDemandIntent
    public let confirmedServerRevision: ChapterServerRevision?
    package init(stored: ChapterBookStoredPreparation, session: ChapterAccountSession) throws {
        guard stored.intent.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        self.session = session; localIntent = stored.intent
        confirmedServerRevision = stored.pending ? nil : stored.confirmedServerRevision
    }
}

/// Exact per-target metadata replay result. The prefix ends AT this manifest,
/// not at a later chapter head; prior audio need not be downloaded for a seek.
/// This is NOT a media handle, current Worker claim or atomic playback grant.
public struct ChatterboxResolvedBookSegment: Sendable {
    public let scopeID: String
    public let wantedRevision: UInt64
    public let chapterIndex: Int
    public let prepared: ChatterboxPreparedChapterSubmission
    public let manifest: ChapterSegmentManifest
    public let prefix: ChapterSegmentPrefix
    /// An actual rendered local unit boundary, never interpolated word timing.
    public let localStartFrame: Int64
    package init(book: ChatterboxPreparedBookSubmission, intent: ChapterBookDemandIntent, chapterIndex: Int,
                 prepared: ChatterboxPreparedChapterSubmission, manifest: ChapterSegmentManifest,
                 prefix: ChapterSegmentPrefix, localStartFrame: Int64) throws {
        try book.validate(prepared, chapterIndex: chapterIndex)
        try manifest.validate(for: prepared.submission.request, originalText: prepared.submission.originalText)
        guard intent.wanted, intent.wantedRevision > 0, intent.scopeID == book.scope.identifier,
              intent.accountPartition == book.scope.accountPartition,
              prefix.segmentCount == manifest.segmentIndex + 1, prefix.tailSHA256 == (try manifest.sha256()),
              prefix.sourceEnd == manifest.sourceRange.offset + manifest.sourceRange.length,
              prefix.decodedFrameCount == manifest.chapterStartFrame + manifest.audio.decodedFrameCount,
              manifest.audio.units.contains(where: { $0.startFrame == localStartFrame }) else { throw ChapterWorkerError.invalidManifest }
        scopeID = book.scope.identifier; wantedRevision = intent.wantedRevision; self.chapterIndex = chapterIndex
        self.prepared = prepared; self.manifest = manifest; self.prefix = prefix; self.localStartFrame = localStartFrame
    }
}
public struct ChatterboxBookSegmentDelivery: Sendable {
    public let resolution: ChatterboxResolvedBookSegment
    public let artifact: ChapterLocalSegmentArtifact
    package init(resolution: ChatterboxResolvedBookSegment, artifact: ChapterLocalSegmentArtifact) throws {
        guard artifact.session == resolution.prepared.submission.session, artifact.manifest == resolution.manifest,
              artifact.request.accountPartition == resolution.prepared.submission.request.accountPartition,
              try artifact.request.renderKey() == resolution.prepared.submission.request.renderKey() else { throw ChapterWorkerError.invalidManifest }
        self.resolution = resolution; self.artifact = artifact
    }
}
/// Validated chapter DATA completion, independent of whether its files have
/// finished playing. Feed seal+finalPrefix to the current chapter player; do not
/// infer this from a following chapter index or global completed count.
public struct ChatterboxResolvedBookChapterCompletion: Sendable {
    public let scopeID: String
    public let wantedRevision: UInt64
    public let chapterIndex: Int
    public let prepared: ChatterboxPreparedChapterSubmission
    public let seal: ChapterSegmentCompletionSeal
    public let finalPrefix: ChapterSegmentPrefix
    package init(book: ChatterboxPreparedBookSubmission, intent: ChapterBookDemandIntent, chapterIndex: Int,
                 prepared: ChatterboxPreparedChapterSubmission, seal: ChapterSegmentCompletionSeal,
                 finalPrefix: ChapterSegmentPrefix) throws {
        try book.validate(prepared, chapterIndex: chapterIndex); try finalPrefix.validate(seal)
        guard intent.wanted, intent.wantedRevision > 0, intent.scopeID == book.scope.identifier,
              intent.accountPartition == book.scope.accountPartition,
              seal.accountPartition == book.scope.accountPartition,
              seal.chapterRenderKey == (try prepared.submission.request.renderKey()) else { throw ChapterWorkerError.invalidManifest }
        scopeID = book.scope.identifier; wantedRevision = intent.wantedRevision; self.chapterIndex = chapterIndex
        self.prepared = prepared; self.seal = seal; self.finalPrefix = finalPrefix
    }
}
public enum ChatterboxBookPhase: Sendable {
    case unavailable, waitingForSource, queued, rendering, publishing, complete, failed
}
public enum ChatterboxBookResolution: Sendable {
    case segment(ChatterboxResolvedBookSegment)
    case chapterComplete(ChatterboxResolvedBookChapterCompletion)
    case waiting(ChatterboxBookPhase)
    /// Only after SDK validation of all original spine entries, silent source
    /// evidence and ordered chapter/book seals under current intent. Not count==N.
    case endOfBook
}
public struct ChatterboxBookServiceUpdate: Sendable {
    public let session: ChapterAccountSession
    public let scopeID: String
    public let sequence: UInt64
    public let demandReceipt: ChatterboxBookDemandReceipt
    public let phase: ChatterboxBookPhase
    /// Real admitted/complete entry counts. Neither counts nor metadata provide
    /// media custody; full book completion additionally requires verified seals.
    public let admittedSpineEntries, completeSpineEntries, totalSpineEntries: Int
    package init(receipt: ChatterboxBookDemandReceipt, sequence: UInt64, phase: ChatterboxBookPhase,
                 admittedSpineEntries: Int, completeSpineEntries: Int, totalSpineEntries: Int) throws {
        guard sequence > 0, (1...4096).contains(totalSpineEntries), (0...totalSpineEntries).contains(admittedSpineEntries),
              (0...admittedSpineEntries).contains(completeSpineEntries) else { throw ChapterWorkerError.invalidManifest }
        if case .complete = phase, completeSpineEntries != totalSpineEntries { throw ChapterWorkerError.invalidManifest }
        session = receipt.session; scopeID = receipt.localIntent.scopeID; self.sequence = sequence
        demandReceipt = receipt; self.phase = phase; self.admittedSpineEntries = admittedSpineEntries
        self.completeSpineEntries = completeSpineEntries; self.totalSpineEntries = totalSpineEntries
    }
}

/// Shared Reader boundary for REAL separate-host book delivery. Declarations do
/// not register/activate a provider. Source/book/segment components are not a
/// shipping factory. A local same-process pair is not an implementation of this
/// iCloud bridge. Validate current account/intent before/after every await and
/// native/file callback; consumers repeat epoch/seek checks before installing.
public protocol ChatterboxPreparedBookService: Sendable {
    func catalog(session: ChapterAccountSession) async throws -> ChatterboxStockCatalog
    /// Returns after durable primary preparation intent, not all source/audio.
    /// Own a bounded lazy-source admission task, independent of Play/Pause. On
    /// close join it and retain admitted data/pending work for source resumption.
    func begin(_ book: ChatterboxPreparedBookSubmission, source: any ChatterboxBookSourceProvider,
               priority: ChapterBookPriority, session: ChapterAccountSession) async throws -> ChatterboxBookDemandReceipt
    func resumeSourceAdmission(scopeID: String, source: any ChatterboxBookSourceProvider,
                               session: ChapterAccountSession) async throws
    /// SDK durable exact-scope/settings recovery, never app-side plan stashing.
    func preparedBook(scopeID: String, session: ChapterAccountSession) async throws -> ChatterboxPreparedBookSubmission?
    func prioritize(_ position: ChapterBookPriority, scopeID: String, session: ChapterAccountSession) async throws -> ChatterboxBookDemandReceipt
    /// SDK replays/verifies bounded ordered metadata prefix through the target.
    /// No earlier audio download; source/unit maps supply actual seek boundary.
    func resolve(scopeID: String, position: ChapterBookPriority, session: ChapterAccountSession) async throws -> ChatterboxBookResolution
    /// Cross chapter boundaries only after verified chapter seal and original
    /// silent-entry handling. Missing next data waits; it never plays an old file.
    func successor(of segment: ChatterboxResolvedBookSegment, session: ChapterAccountSession) async throws -> ChatterboxBookResolution
    /// Only after a chapter-complete result: resolve subsequent original-spine
    /// data (or wait/end). Prefetching may happen before prior audio is heard;
    /// this method never stops/plays that audio or changes listening intent.
    func successor(of completion: ChatterboxResolvedBookChapterCompletion, session: ChapterAccountSession) async throws -> ChatterboxBookResolution
    /// Initial/full sticky snapshots, bufferingNewest(1), increasing sequence;
    /// observation never submits intent or starts audio downloads/inference.
    func updates(scopeID: String, session: ChapterAccountSession) async throws -> AsyncThrowingStream<ChatterboxBookServiceUpdate, Error>
    /// Actual private copy/hash/codec decode and exact current-book acceptance
    /// under OWN Reader epoch; retain delivery handles throughout queued playback.
    func download(_ segment: ChatterboxResolvedBookSegment, session: ChapterAccountSession) async throws -> ChatterboxBookSegmentDelivery
    func cancelPreparation(scopeID: String, session: ChapterAccountSession) async throws -> ChatterboxBookDemandReceipt
    /// Host calls directly in its event turn. Stop admission/cancel owned calls;
    /// async close is the join barrier and preserves durable book preparation.
    func stopRequests()
    func close(session: ChapterAccountSession) async throws
}
