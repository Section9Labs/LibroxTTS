import Foundation

public struct ChapterAccountSession: Sendable, Equatable {
    public let accountPartition: String
    public let epoch: UUID
}

/// Local callback fencing, independent of persistent per-account queue identity.
/// Host derives partition from container/private database/environment/account ID.
/// Open a fresh epoch for EVERY account lifecycle, including sign-out then A→A.
/// Validate again after each await before adopting results or updating local UI.
public actor ChapterAccountSessionGate {
    private var current: ChapterAccountSession?
    public init() {}

    public func open(accountPartition: String) throws -> ChapterAccountSession {
        guard isDigest(accountPartition) else { throw ChapterWorkerError.invalidIdentity }
        let session = ChapterAccountSession(accountPartition: accountPartition, epoch: UUID())
        current = session; return session
    }

    public func close() { current = nil }

    public func validate(_ session: ChapterAccountSession) throws {
        guard current == session else { throw ChapterWorkerError.accountMismatch }
    }
}
