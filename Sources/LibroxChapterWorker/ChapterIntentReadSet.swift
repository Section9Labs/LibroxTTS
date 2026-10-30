import Foundation

/// An exact local Reader journal observation. Serialization does not make it
/// current: validate through the Reader authority again at every work boundary.
public struct ChapterIntentReadSet: Codable, Sendable, Equatable {
    public let intent: ChapterDemandIntent
    public let sourceReference: ChapterLocalSourceReference
    public let renderPlanReference: ChapterLocalRenderPlanReference

    init(intent: ChapterDemandIntent, sourceReference: ChapterLocalSourceReference,
         renderPlanReference: ChapterLocalRenderPlanReference) throws {
        try intent.request.validate()
        guard intent.wanted, intent.revision > 0, intent.request.recipe.watermarkRevision == "disabled-1"
        else { throw ChapterWorkerError.invalidTransition }
        self.intent = intent; self.sourceReference = sourceReference; self.renderPlanReference = renderPlanReference
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(intent: c.decode(ChapterDemandIntent.self, forKey: .intent),
            sourceReference: c.decode(ChapterLocalSourceReference.self, forKey: .sourceReference),
            renderPlanReference: c.decode(ChapterLocalRenderPlanReference.self, forKey: .renderPlanReference))
    }
    private enum CodingKeys: String, CodingKey { case intent, sourceReference, renderPlanReference }
}

/// Read-only authority boundary. A cross-process host must authenticate its
/// Reader endpoint; never substitute a cached file or an always-true provider.
/// The companion does not open or receive the Reader's mutable outbox handle.
public protocol ChapterIntentAuthority: Sendable {
    func validateCurrent(_ readSet: ChapterIntentReadSet) async throws -> Bool
}

/// Reader-process adapter. It exposes no mutation/journal paths. The eventual
/// authenticated IPC adapter must execute these checks inside the Reader owner.
/// This in-process value is not itself an IPC implementation or durable head.
public struct ChapterReaderIntentAuthority: ChapterIntentAuthority {
    private let outbox: ChapterDemandOutbox
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    public init(outbox: ChapterDemandOutbox, session: ChapterAccountSession, gate: ChapterAccountSessionGate) {
        self.outbox = outbox; self.session = session; self.gate = gate
    }
    public func validateCurrent(_ readSet: ChapterIntentReadSet) async throws -> Bool {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard readSet.intent.request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let result = try await outbox.validateCurrent(readSet)
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        return result
    }
}
