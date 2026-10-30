import Foundation

public enum ChapterDemandTransportError: Error, Equatable {
    case conflict, uncertain, invalidRecord, inconsistentSnapshot, remoteRevisionAhead, retryLimit, busy
    case accountUnavailable, configurationUnavailable, quotaExceeded
    case operationCancelled, offline, retryAfter(seconds: TimeInterval)
}

struct ChapterRemoteDemand: Codable, Sendable, Equatable {
    let version: Int
    let intent: ChapterDemandIntent
    let acceptedQueueRevision: UInt64
}
struct ChapterRemoteQueueIntent: Codable, Sendable, Equatable {
    let version: Int
    let request: ChapterRenderRequest
    let revision: UInt64
    var activeDevices: [String: UInt64]
}
struct ChapterDemandSnapshot: Sendable {
    let token: UUID
    let demand: ChapterRemoteDemand?
    let queue: ChapterRemoteQueueIntent?
}
struct ChapterDemandProposal: Sendable {
    let demand: ChapterRemoteDemand
    let queue: ChapterRemoteQueueIntent
}

/// Internal seam for deterministic transaction-interleaving tests. Production
/// callers construct the real private-custom-zone CloudKit adapter explicitly.
protocol ChapterDemandTransport: Sendable {
    func read(_ intent: ChapterDemandIntent, session: ChapterAccountSession) async throws -> ChapterDemandSnapshot
    func commit(_ proposal: ChapterDemandProposal, snapshot: ChapterDemandSnapshot,
                session: ChapterAccountSession) async throws -> ChapterServerRevision
    func discard(_ snapshot: ChapterDemandSnapshot) async
}

enum ChapterDemandTransition {
    static func proposal(_ intent: ChapterDemandIntent, from snapshot: ChapterDemandSnapshot) throws -> ChapterDemandProposal {
        try intent.request.validate()
        guard intent.revision > 0, intent.request.recipe.watermarkRevision == "disabled-1"
        else { throw ChapterDemandTransportError.invalidRecord }
        let device = intent.deviceID.uuidString.lowercased()
        if let queue = snapshot.queue {
            try queue.request.validate()
            guard queue.version == 1, queue.request == intent.request, queue.revision > 0,
                  queue.activeDevices.count <= 256,
                  queue.activeDevices.allSatisfy({ UUID(uuidString: $0.key)?.uuidString.lowercased() == $0.key && $0.value > 0 })
            else { throw ChapterDemandTransportError.invalidRecord }
        }
        if let old = snapshot.demand {
            guard old.version == 1, old.intent.request == intent.request, old.intent.deviceID == intent.deviceID,
                  old.intent.revision > 0, old.acceptedQueueRevision > 0 else { throw ChapterDemandTransportError.invalidRecord }
            guard let queue = snapshot.queue, queue.revision >= old.acceptedQueueRevision,
                  (old.intent.wanted ? queue.activeDevices[device] == old.intent.revision : queue.activeDevices[device] == nil)
            else { throw ChapterDemandTransportError.inconsistentSnapshot }
            guard old.intent.revision <= intent.revision else { throw ChapterDemandTransportError.remoteRevisionAhead }
            if old.intent.revision == intent.revision {
                guard old.intent == intent else { throw ChapterDemandTransportError.invalidRecord }
                // Still perform conditional atomic save of BOTH records. A fetch
                // alone is not enough to confirm a lost/ambiguous acknowledgement.
                return .init(demand: old, queue: queue)
            }
        } else if snapshot.queue?.activeDevices[device] != nil {
            throw ChapterDemandTransportError.inconsistentSnapshot
        }
        let revision = snapshot.queue?.revision ?? 0
        guard revision < .max else { throw ChapterDemandTransportError.invalidRecord }
        var devices = snapshot.queue?.activeDevices ?? [:]
        if intent.wanted { devices[device] = intent.revision } else { devices.removeValue(forKey: device) }
        guard devices.count <= 256 else { throw ChapterDemandTransportError.invalidRecord }
        let next = revision + 1
        return .init(demand: .init(version: 1, intent: intent, acceptedQueueRevision: next),
            queue: .init(version: 1, request: intent.request, revision: next, activeDevices: devices))
    }
}

/// Finite demand-only synchronization. No source/audio upload, render claim,
/// lease, publication or worker-ready implementation is implied by this stage.
public actor ChapterDemandReconciler {
    private let outbox: ChapterDemandOutbox
    private let transport: any ChapterDemandTransport
    private let gate: ChapterAccountSessionGate
    private var occupied = false

    public init(outbox: ChapterDemandOutbox, cloud: ChapterCloudDemandTransport, gate: ChapterAccountSessionGate) {
        self.outbox = outbox; transport = cloud; self.gate = gate
    }
    init(outbox: ChapterDemandOutbox, transport: any ChapterDemandTransport, gate: ChapterAccountSessionGate) {
        self.outbox = outbox; self.transport = transport; self.gate = gate
    }
    public func flush(session: ChapterAccountSession, maximumIntents: Int = 16) async throws -> [ChapterDemandReceipt] {
        guard !occupied else { throw ChapterDemandTransportError.busy }
        guard (1...16).contains(maximumIntents), session.accountPartition == outbox.accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        occupied = true; defer { occupied = false }
        try await valid(session)
        let pending = try await outbox.pending()
        try await valid(session)
        var receipts: [ChapterDemandReceipt] = []
        for intent in pending.prefix(maximumIntents) {
            var confirmed: ChapterServerRevision?
            for _ in 0..<3 {
                try await valid(session)
                do {
                    let snapshot = try await transport.read(intent, session: session)
                    do {
                        try await valid(session)
                        let proposal = try ChapterDemandTransition.proposal(intent, from: snapshot)
                        confirmed = try await transport.commit(proposal, snapshot: snapshot, session: session)
                    } catch {
                        await transport.discard(snapshot)
                        throw error
                    }
                    try await valid(session)
                    break
                } catch let error as ChapterDemandTransportError {
                    switch error {
                    case .conflict, .uncertain, .inconsistentSnapshot: continue
                    default: throw error
                    }
                }
            }
            guard let confirmed else { throw ChapterDemandTransportError.retryLimit }
            try await valid(session)
            let adopted = try await outbox.confirm(intent, serverRevision: confirmed)
            try await valid(session)
            if adopted {
                receipts.append(try .init(request: intent.request, session: session, deviceID: intent.deviceID,
                    intentRevision: intent.revision, wanted: intent.wanted, delivery: .acknowledged(serverRevision: confirmed)))
            }
        }
        return receipts
    }
    /// Recover an already confirmed device receipt after partial batch failure,
    /// cancellation or process reopen. No new CloudKit request is made.
    public func confirmedReceipt(for request: ChapterRenderRequest, session: ChapterAccountSession) async throws -> ChapterDemandReceipt? {
        guard request.accountPartition == session.accountPartition,
              session.accountPartition == outbox.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try await valid(session)
        let confirmation = try await outbox.confirmation(for: request)
        try await valid(session)
        guard let confirmation else { return nil }
        return try .init(request: request, session: session, deviceID: confirmation.intent.deviceID,
            intentRevision: confirmation.intent.revision, wanted: confirmation.intent.wanted,
            delivery: .acknowledged(serverRevision: confirmation.serverRevision))
    }
    private func valid(_ session: ChapterAccountSession) async throws {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
    }
}
