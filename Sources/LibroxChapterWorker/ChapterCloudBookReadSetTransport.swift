import Foundation
import CloudKit

enum ChapterCloudBookReadSetError: Error { case absent }
package struct ChapterBookReadSetServerReceipt: Sendable {
    package let identity: ChapterBookReadSetIdentity
    package let session: ChapterAccountSession
    package let revision: ChapterServerRevision
    fileprivate init(identity: ChapterBookReadSetIdentity, session: ChapterAccountSession, revision: ChapterServerRevision) {
        self.identity = identity; self.session = session; self.revision = revision
    }
}

/// Immutable FULL policy/spine/read-set CONTENT. Not the mutable current intent
/// or a Worker claim. The actual current member CAS must name this exact asset.
package actor ChapterCloudBookReadSetTransport {
    package static let recordType = "LibroxBookReadSetV1"
    private let store: any ChapterCloudAssetStore
    private let session: ChapterAccountSession
    private let gate: ChapterAccountSessionGate
    private let storage: URL
    private let authorize: @Sendable () async throws -> Void
    private var occupied = false
    package init(container: CKContainer, account: ChapterCloudAccountIdentity, session: ChapterAccountSession,
                 gate: ChapterAccountSessionGate, captureStorage: URL,
                 authorizeAssetTransfer: @escaping @Sendable () async throws -> Void) throws {
        guard container.containerIdentifier == account.containerIdentifier, account.accountPartition == session.accountPartition,
              captureStorage.isFileURL else { throw ChapterWorkerError.invalidIdentity }
        store = NativeChapterCloudAssetStore(database: container.privateCloudDatabase, recordType: Self.recordType, prefix: "brs-")
        self.session = session; self.gate = gate; storage = captureStorage; authorize = authorizeAssetTransfer
    }
    init(store: any ChapterCloudAssetStore, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
         captureStorage: URL, authorize: @escaping @Sendable () async throws -> Void = {}) {
        self.store = store; self.session = session; self.gate = gate; storage = captureStorage; self.authorize = authorize
    }
    private func valid(_ identity: ChapterBookReadSetIdentity) async throws {
        try identity.validate(); try Task.checkCancellation()
        guard identity.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        try await gate.validate(session); try Task.checkCancellation()
    }
    private func authorized(_ identity: ChapterBookReadSetIdentity) async throws {
        try await valid(identity); try await authorize(); try await valid(identity)
    }
    private static func validate(_ snapshot: ChapterCloudAssetSnapshot, identity: ChapterBookReadSetIdentity) throws {
        guard snapshot.key == (try identity.key()), !snapshot.tag.isEmpty, snapshot.tag.utf8.count <= 1024,
              try ChapterBookReadSetIdentity.decode(snapshot.metadata) == identity else { throw ChapterDemandTransportError.invalidRecord }
    }
    private func receipt(_ snapshot: ChapterCloudAssetSnapshot, identity: ChapterBookReadSetIdentity) throws -> ChapterBookReadSetServerReceipt {
        try Self.validate(snapshot, identity: identity)
        let data = try JSONEncoder().encode([session.accountPartition, snapshot.key, snapshot.tag,
            ChapterCloudFileCapture.digest(snapshot.metadata)])
        return .init(identity: identity, session: session, revision: try .init(opaqueValue: ChapterCloudFileCapture.digest(data)))
    }
    private func fetch(_ identity: ChapterBookReadSetIdentity, capture: ChapterCloudAssetCapture? = nil) async throws -> ChapterCloudAssetSnapshot? {
        try await authorized(identity)
        do {
            let value = try await store.fetch(key: identity.key(), capture: capture)
            try await valid(identity); return value
        } catch { try await valid(identity); throw error }
    }
    private func verified(_ metadata: ChapterCloudAssetSnapshot, identity: ChapterBookReadSetIdentity) async throws -> ChapterBookReadSet {
        try Self.validate(metadata, identity: identity)
        let capture = ChapterCloudAssetCapture(expected: metadata, bytes: identity.byteCount, sha256: identity.payloadSHA256,
            maximum: Int64(ChapterBookReadSet.maximumBytes), session: session, storage: storage)
        guard let value = try await fetch(identity, capture: capture), value.tag == metadata.tag,
              value.metadata == metadata.metadata, let file = value.file else { throw ChapterDemandTransportError.conflict }
        try Self.validate(value, identity: identity)
        let bytes = try await file.data(session: session, gate: gate, maximum: Int64(ChapterBookReadSet.maximumBytes))
        let readSet = try identity.decodeContent(bytes)
        try await valid(identity); return readSet
    }
    package func download(_ identity: ChapterBookReadSetIdentity) async throws -> ChapterBookReadSet {
        try await valid(identity)
        guard !occupied else { throw ChapterDemandTransportError.busy }; occupied = true; defer { occupied = false }
        guard let metadata = try await fetch(identity) else { throw ChapterCloudBookReadSetError.absent }
        return try await verified(metadata, identity: identity)
    }
    /// Confirmed immutable content only. No native current-book acknowledgement
    /// or readiness can be inferred from this return value.
    package func upload(_ readSet: ChapterBookReadSet) async throws -> ChapterBookReadSetServerReceipt {
        let identity = try ChapterBookReadSetIdentity(readSet)
        try await valid(identity)
        guard !occupied else { throw ChapterDemandTransportError.busy }; occupied = true; defer { occupied = false }
        if let metadata = try await fetch(identity) {
            _ = try await verified(metadata, identity: identity); return try receipt(metadata, identity: identity)
        }
        let bytes = try readSet.encoded()
        do {
            let session = session, gate = gate, storage = storage
            let producer = Task.detached(priority: .utility) {
                try ChapterCloudFileCapture.create(bytes, maximum: Int64(ChapterBookReadSet.maximumBytes), session: session,
                    storageDirectory: storage, check: { try Task.checkCancellation() })
            }
            let file = try await withTaskCancellationHandler { try await producer.value } onCancel: { producer.cancel() }
            let saved = try await file.withFileAccess(session: session, gate: gate) { url in
                try await self.authorized(identity)
                return try await self.store.insert(key: identity.key(), metadata: identity.encoded(), asset: url)
            }
            try await valid(identity); return try receipt(saved, identity: identity)
        } catch {
            try await valid(identity)
            guard let failure = error as? ChapterDemandTransportError, failure == .uncertain || failure == .conflict,
                  let metadata = try await fetch(identity) else { throw error }
            _ = try await verified(metadata, identity: identity); return try receipt(metadata, identity: identity)
        }
    }
}
