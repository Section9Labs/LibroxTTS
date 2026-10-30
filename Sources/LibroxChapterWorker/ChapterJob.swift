import Foundation

public struct ChapterClaim: Codable, Sendable, Equatable {
    public let workerID: UUID
    public let generation: UInt64
    public let expiresAt: Date
}

/// Transport-independent transition rules. A real CloudKit adapter MUST persist
/// every mutation with conditional change-tag saves and atomically fence job,
/// lease and publication records. This value is not a distributed lock.
public struct ChapterJob: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case queued, rendering, publishing, ready, cancelled, failed }
    public let request: ChapterRenderRequest
    public private(set) var phase: Phase = .queued
    public private(set) var claim: ChapterClaim?
    public private(set) var generation: UInt64 = 0
    /// Every effective demand change must share the transport's atomic job save.
    public private(set) var intentRevision: UInt64 = 0
    public private(set) var artifact: ChapterArtifactManifest?
    public private(set) var demandingDevices: Set<UUID>

    public init(request: ChapterRenderRequest, demandingDevice: UUID) throws {
        try request.validate(); self.request = request; demandingDevices = [demandingDevice]
    }

    public mutating func addDemand(_ device: UUID, accountPartition: String) throws {
        try account(accountPartition)
        guard phase != .failed else { throw ChapterWorkerError.invalidTransition }
        if !demandingDevices.contains(device) {
            guard intentRevision < .max else { throw ChapterWorkerError.invalidTransition }
            demandingDevices.insert(device); intentRevision += 1
        }
        if phase == .cancelled { phase = .queued }
    }

    public mutating func cancelDemand(_ device: UUID, accountPartition: String) throws {
        try account(accountPartition)
        if demandingDevices.contains(device) {
            guard intentRevision < .max else { throw ChapterWorkerError.invalidTransition }
            demandingDevices.remove(device); intentRevision += 1
        }
        if demandingDevices.isEmpty, phase != .ready {
            claim = nil; phase = .cancelled
        }
    }

    public mutating func acquire(workerID: UUID, accountPartition: String, now: Date,
                                 leaseSeconds: TimeInterval = 300, enabled: Bool) throws -> ChapterClaim {
        try account(accountPartition)
        guard enabled else { throw ChapterWorkerError.disabled }
        guard now.timeIntervalSince1970.isFinite, (1...300).contains(leaseSeconds), !demandingDevices.isEmpty,
              generation < .max else { throw ChapterWorkerError.invalidTransition }
        guard phase == .queued || ((phase == .rendering || phase == .publishing) && claim.map { $0.expiresAt <= now } == true)
        else { throw ChapterWorkerError.busy }
        generation += 1
        let value = ChapterClaim(workerID: workerID, generation: generation, expiresAt: now.addingTimeInterval(leaseSeconds))
        claim = value; phase = .rendering
        return value
    }

    public mutating func renew(_ token: ChapterClaim, accountPartition: String, now: Date,
                               leaseSeconds: TimeInterval = 300) throws -> ChapterClaim {
        try current(token, accountPartition: accountPartition, now: now)
        guard (1...300).contains(leaseSeconds) else { throw ChapterWorkerError.invalidTransition }
        let value = ChapterClaim(workerID: token.workerID, generation: token.generation,
                                 expiresAt: now.addingTimeInterval(leaseSeconds))
        claim = value; return value
    }

    public mutating func beginPublication(_ token: ChapterClaim, expectedIntentRevision: UInt64,
                                          accountPartition: String, now: Date) throws {
        try current(token, accountPartition: accountPartition, now: now)
        guard expectedIntentRevision == intentRevision else { throw ChapterWorkerError.staleClaim }
        guard phase == .rendering else { throw ChapterWorkerError.invalidTransition }
        phase = .publishing
    }

    public mutating func publish(_ manifest: ChapterArtifactManifest, token: ChapterClaim,
                                 expectedIntentRevision: UInt64, accountPartition: String, now: Date) throws {
        try current(token, accountPartition: accountPartition, now: now)
        guard expectedIntentRevision == intentRevision else { throw ChapterWorkerError.staleClaim }
        guard phase == .publishing else { throw ChapterWorkerError.invalidTransition }
        try manifest.validate(for: request)
        artifact = manifest; claim = nil; phase = .ready
    }

    /// Disable/relinquish only AFTER the renderer and its children have joined.
    /// Removing the claim fences any late callback; completed artifacts survive.
    public mutating func relinquishAfterJoining(_ token: ChapterClaim, accountPartition: String, now: Date) throws {
        try current(token, accountPartition: accountPartition, now: now)
        claim = nil; phase = demandingDevices.isEmpty ? .cancelled : .queued
    }

    private func account(_ partition: String) throws {
        try request.validate()
        guard request.accountPartition == partition else { throw ChapterWorkerError.accountMismatch }
    }

    private func current(_ token: ChapterClaim, accountPartition: String, now: Date) throws {
        try account(accountPartition)
        guard now.timeIntervalSince1970.isFinite, claim == token, token.expiresAt > now,
              !demandingDevices.isEmpty, phase == .rendering || phase == .publishing
        else { throw ChapterWorkerError.staleClaim }
    }
}
