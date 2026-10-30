import Foundation
import LibroxChapterWorker

/// Source-independent catalog display/support data. Descriptor metadata alone
/// never establishes availability or listening approval. No generic recipe is
/// exposed because expression/options identities depend on the actual chapter.
public struct ChatterboxStockCapability: Sendable {
    public let descriptor: ChatterboxStockVoiceDescriptor
    public let availability: ChapterStockCapability.Availability
    public let listeningApproval: ChapterStockCapability.ListeningApproval
    public let deliveryFormats: [ChapterAudioDelivery]
    public init(descriptor: ChatterboxStockVoiceDescriptor,
                availability: ChapterStockCapability.Availability = .unavailable,
                listeningApproval: ChapterStockCapability.ListeningApproval = .pending,
                deliveryFormats: [ChapterAudioDelivery] = [.smaller, .lossless]) throws {
        guard !deliveryFormats.isEmpty, deliveryFormats.count <= ChapterAudioDelivery.allCases.count,
              Set(deliveryFormats).count == deliveryFormats.count else { throw ChapterServiceError.invalidCatalog }
        self.descriptor = descriptor; self.availability = availability
        self.listeningApproval = listeningApproval; self.deliveryFormats = deliveryFormats
    }
}
public struct ChatterboxStockCatalog: Sendable {
    public let session: ChapterAccountSession
    public let voices: [ChatterboxStockCapability]
    public init(session: ChapterAccountSession, voices: [ChatterboxStockCapability]) throws {
        // V1 is exactly one stock identity, with supported EN/ES metadata. An
        // unavailable service must throw, not return an invented empty catalog.
        guard voices.count == 1 else { throw ChapterServiceError.invalidCatalog }
        self.session = session; self.voices = voices
    }
}

/// Production source-bound Reader boundary. Intentionally separate from legacy
/// ChapterService/catalog fixtures: there is NO adapter that drops the plan or
/// reconstructs options from hashes. This protocol alone activates no provider.
/// Implementations validate session/epoch and cancellation before AND after
/// every await, including file/transport callbacks. Consumers repeat those
/// checks before installing state or using a returned artifact.
public protocol ChatterboxPreparedChapterService: Sendable {
    /// Actual qualified service catalog under the current account/host gate.
    /// Default metadata flags are unavailable/pending; weights are not readiness.
    func catalog(session: ChapterAccountSession) async throws -> ChatterboxStockCatalog
    /// Owns and persists BOTH exact source-bound submission and portable plan.
    /// Returns only after the authoritative local intent triple is durable.
    /// Lost acknowledgements reconcile that journal; they are not rollbacks.
    func submit(_ prepared: ChatterboxPreparedChapterSubmission) async throws -> ChapterDemandReceipt
    /// Remove only this device's demand; preserve other devices, stored options
    /// and completed artifacts. A global phase never acknowledges this device.
    func cancel(request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChapterDemandReceipt
    /// Full sticky local-device receipts, bufferingNewest(1), monotonically
    /// increasing subscription sequence; metadata never becomes playable.
    /// Send an initial current snapshot. Observation never submits demand or
    /// starts a download; subscription cancellation releases owned work, and
    /// connection/account close finishes the stream.
    func updates(for request: ChapterRenderRequest, session: ChapterAccountSession) async throws
        -> AsyncThrowingStream<ChapterServiceUpdate, Error>
    /// SDK-only recovery from its exact durable source/plan references. nil means
    /// no stored complete pair; corruption/unavailable authority throws. No
    /// defaults from hashes, app-side plan stash or producer epoch is allowed.
    func preparedSubmission(for request: ChapterRenderRequest, session: ChapterAccountSession) async throws
        -> ChatterboxPreparedChapterSubmission?
    /// Actual copied/decoded custody and current Reader wanted-intent acceptance.
    /// The complete pair carries expected exact source/options into verification.
    func download(_ prepared: ChatterboxPreparedChapterSubmission) async throws -> ChapterLocalArtifact
    /// Revoke this connection, cancel/join its calls and finish subscriptions;
    /// preserve durable demand, references and completed publications.
    func close(session: ChapterAccountSession) async throws
}
