import Foundation

/// Compile-time host boundary only. These types do not provide a queue, renderer,
/// CloudKit transport, approved voice catalog, or evidence of remote delivery.
public enum ChapterServiceError: Error, Equatable {
    case invalidProgress, invalidReceipt, invalidUpdate, invalidCatalog, unsupportedPolicy
}

/// The exact reader extraction, never plain-text re-extraction or private voice data.
public struct ChapterSubmission: Sendable {
    public let request: ChapterRenderRequest
    public let originalText: String
    public let session: ChapterAccountSession
    public init(request: ChapterRenderRequest, originalText: String, session: ChapterAccountSession) throws {
        try validateServiceRequest(request, session: session)
        try request.source.validate(text: originalText)
        self.request = request; self.originalText = originalText; self.session = session
    }
}

public struct ChapterMeasuredProgress: Sendable, Equatable {
    public enum Unit: Sendable { case renderedUnits, downloadedBytes }
    public let completed: Int64
    public let total: Int64
    public let unit: Unit
    public init(completed: Int64, total: Int64, unit: Unit) throws {
        let limit: Int64 = unit == .renderedUnits ? 100_000 : 1_073_741_824
        guard total > 0, total <= limit, completed >= 0, completed <= total else { throw ChapterServiceError.invalidProgress }
        self.completed = completed; self.total = total; self.unit = unit
    }
}

/// Availability means the end-to-end service can accept this recipe within its
/// advertised source limit, not merely that weights are installed or a short
/// excerpt rendered. Approval separately records listening acceptance.
/// Available + pending is not release approval; clients must not split a chapter
/// to evade the limit or advertise whole-chapter support from excerpt evidence.
public struct ChapterStockCapability: Sendable, Equatable {
    public enum Availability: Sendable, Equatable { case available, unavailable }
    public enum ListeningApproval: Sendable, Equatable { case pending, approved, rejected }
    public let id: String
    public let displayName: String
    public let recipe: ChapterRenderRecipe
    public let maximumSourceUTF16Length: Int
    /// Advertise only formats supported through encoding, cloud transport and
    /// verified local adoption. This is separate from listening approval.
    public let deliveryFormats: [ChapterAudioDelivery]
    public let availability: Availability
    public let listeningApproval: ListeningApproval
    public init(id: String, displayName: String, recipe: ChapterRenderRecipe,
                maximumSourceUTF16Length: Int, availability: Availability, listeningApproval: ListeningApproval,
                deliveryFormats: [ChapterAudioDelivery] = [.lossless]) throws {
        try recipe.validate()
        guard recipe.watermarkRevision == "disabled-1" else { throw ChapterServiceError.unsupportedPolicy }
        guard boundedLabel(id, limit: 256), boundedLabel(displayName, limit: 256),
              (1...10_000_000).contains(maximumSourceUTF16Length), !deliveryFormats.isEmpty,
              Set(deliveryFormats).count == deliveryFormats.count else { throw ChapterServiceError.invalidCatalog }
        self.id = id; self.displayName = displayName; self.recipe = recipe
        self.maximumSourceUTF16Length = maximumSourceUTF16Length
        self.availability = availability; self.listeningApproval = listeningApproval; self.deliveryFormats = deliveryFormats
    }
}

public struct ChapterStockCatalog: Sendable {
    public let session: ChapterAccountSession
    public let capabilities: [ChapterStockCapability]
    public init(session: ChapterAccountSession, capabilities: [ChapterStockCapability]) throws {
        guard isDigest(session.accountPartition), capabilities.count <= 256,
              Set(capabilities.map(\.id)).count == capabilities.count else { throw ChapterServiceError.invalidCatalog }
        self.session = session; self.capabilities = capabilities
    }
}

/// Adapter-issued version identity only. Not a sortable clock, lease, delivery
/// proof, or raw CloudKit record. No Comparable conformance is intentional.
public struct ChapterServerRevision: Sendable, Equatable {
    public let opaqueValue: String
    public init(opaqueValue: String) throws {
        guard boundedLabel(opaqueValue, limit: 1_024) else { throw ChapterServiceError.invalidReceipt }
        self.opaqueValue = opaqueValue
    }
}

/// Local persistence and network submission are NOT server acknowledgement.
/// A server revision may be supplied only by the real conditional transaction
/// adapter after accepting this exact device/revision/wanted value.
public struct ChapterDemandReceipt: Sendable, Equatable {
    public enum Delivery: Sendable, Equatable {
        case localIntent
        case submitted
        case acknowledged(serverRevision: ChapterServerRevision)
    }
    public let request: ChapterRenderRequest
    public let session: ChapterAccountSession
    public let deviceID: UUID
    public let intentRevision: UInt64
    public let wanted: Bool
    public let delivery: Delivery
    public init(request: ChapterRenderRequest, session: ChapterAccountSession, deviceID: UUID,
                intentRevision: UInt64, wanted: Bool, delivery: Delivery) throws {
        try validateServiceRequest(request, session: session)
        guard intentRevision > 0 else { throw ChapterServiceError.invalidReceipt }
        self.request = request; self.session = session; self.deviceID = deviceID
        self.intentRevision = intentRevision; self.wanted = wanted; self.delivery = delivery
    }
}

public struct ChapterServiceFailure: Sendable, Equatable {
    public enum Code: Sendable { case account, network, source, recipe, approval, renderer, storage, transport, verification }
    public enum Recovery: Sendable { case retry, signIn, chooseVoice, enableCompanion, freeSpace, none }
    public let code: Code
    public let recovery: Recovery
    public init(code: Code, recovery: Recovery) { self.code = code; self.recovery = recovery }
}

/// Remote metadata has no playable flag. Only SDK-adopted decoded/verified file
/// custody can represent playable, and its exact request AND epoch must match.
public enum ChapterServiceState: Sendable {
    case localIntent, submitted, queued
    case rendering(ChapterMeasuredProgress?)
    case publishing
    case remoteReady(ChapterArtifactManifest)
    case downloading(ChapterMeasuredProgress?)
    case verifying
    case playable(ChapterLocalArtifact)
    case cancelled
    case failed(ChapterServiceFailure)
}

/// Sequence is strictly increasing within one subscription, not a server lease,
/// demand revision or clock. The service must reject stale transport callbacks.
public struct ChapterServiceUpdate: Sendable {
    public let request: ChapterRenderRequest
    public let session: ChapterAccountSession
    public let sequence: UInt64
    public let state: ChapterServiceState
    /// Latest known receipt for this service's durable local device. Retain it
    /// in subsequent FULL snapshots so bufferingNewest(1) cannot erase an ack.
    /// Consumers also match device/revision/wanted against their current intent.
    /// wanted=false may coexist with queued/ready demand from other devices.
    public let demandReceipt: ChapterDemandReceipt?
    public init(request: ChapterRenderRequest, session: ChapterAccountSession, sequence: UInt64,
                state: ChapterServiceState, demandReceipt: ChapterDemandReceipt? = nil) throws {
        try validateServiceRequest(request, session: session)
        guard sequence > 0 else { throw ChapterServiceError.invalidUpdate }
        if let receipt = demandReceipt {
            guard receipt.request == request, receipt.session == session else { throw ChapterServiceError.invalidUpdate }
        }
        switch state {
        case .rendering(let progress):
            guard progress == nil || progress?.unit == .renderedUnits else { throw ChapterServiceError.invalidProgress }
        case .downloading(let progress):
            guard progress == nil || progress?.unit == .downloadedBytes else { throw ChapterServiceError.invalidProgress }
        case .remoteReady(let manifest):
            try manifest.validate(for: request)
            guard ChapterLocalArtifact.Codec(rawValue: manifest.codecRevision) != nil,
                  manifest.decodedFrameCount <= ChapterLocalArtifact.maximumDecodedFrames
            else { throw ChapterServiceError.invalidUpdate }
        case .playable(let artifact):
            guard artifact.request == request, artifact.session == session else { throw ChapterServiceError.invalidUpdate }
        default: break
        }
        self.request = request; self.session = session; self.sequence = sequence; self.state = state
        self.demandReceipt = demandReceipt
    }
}

/// Implementations validate session/cancellation before AND after every await.
/// Consumers repeat gate validation after awaits before adopting state/files.
/// Empty catalogs/unavailable services must not masquerade as working backends.
public protocol ChapterService: Sendable {
    func catalog(session: ChapterAccountSession) async throws -> ChapterStockCatalog
    /// Return only after local intent is durable. Remote delivery is explicit in
    /// the receipt; a local journal acknowledgement alone is never server proof.
    func submit(_ submission: ChapterSubmission) async throws -> ChapterDemandReceipt
    /// Remove only this device's demand, preserving other devices and artifacts.
    func cancel(request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChapterDemandReceipt
    /// Snapshot stream for one request/epoch: bufferingNewest(1), initial current
    /// snapshot, monotonically increasing sequence. Coalescing may skip phases.
    /// Cancellation releases subscription work; account close finishes the stream.
    /// Observation does not submit demand or start a download. Never emit playable
    /// from a remote-ready record or from a previous epoch's cached handle.
    /// Include the latest local-device demand receipt in every subsequent full
    /// snapshot; a global job phase cannot acknowledge this device's cancellation.
    func updates(for request: ChapterRenderRequest, session: ChapterAccountSession) async throws
        -> AsyncThrowingStream<ChapterServiceUpdate, Error>
    /// Owns cancellable network transfer and SDK adoption with exact source text.
    /// Returns only complete verified custody, never a CKAsset or temporary URL.
    /// Host network permission applies to each asset operation, including retries.
    func download(_ submission: ChapterSubmission) async throws -> ChapterLocalArtifact
    /// Revoke this epoch, cancel and join its operations, and finish its streams.
    /// This does not cancel durable demand or delete already prepared artifacts.
    func close(session: ChapterAccountSession) async throws
}

/// Native host admission is synchronous; SDK operations/children remain owned
/// until join. Start must not reopen admission while a prior shutdown is pending.
/// Implementations run render/file/network work away from the UI actor.
@MainActor public protocol ChapterWorkerService: AnyObject, Sendable {
    func start(session: ChapterAccountSession) async throws
    func stopClaims()
    func cancelAndJoin() async throws
    /// Called only after successful join; real transport conditionally fences
    /// the claim/intent generation. Failed join MUST NOT relinquish a live claim.
    func relinquishAfterJoining(session: ChapterAccountSession) async throws
}

private func validateServiceRequest(_ request: ChapterRenderRequest, session: ChapterAccountSession) throws {
    try request.validate()
    guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
    guard request.recipe.watermarkRevision == "disabled-1" else { throw ChapterServiceError.unsupportedPolicy }
}
private func boundedLabel(_ value: String, limit: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
}
