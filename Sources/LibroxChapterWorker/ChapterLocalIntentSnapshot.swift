import Foundation
import CryptoKit

public enum ChapterLocalIntentError: Error, Equatable { case invalidRecord, staleIntent, incompleteIntent, budget }
public struct ChapterLocalIntentReference: Codable, Sendable, Equatable {
    public let identifier: String
    public init(identifier: String) throws {
        guard isDigest(identifier) else { throw ChapterWorkerError.invalidIdentity }
        self.identifier = identifier
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identifier: c.decode(String.self, forKey: .identifier))
    }
    private enum CodingKeys: String, CodingKey { case identifier }
}
/// Immutable publication identity, not a current-wanted grant or worker claim.
public struct ChapterLocalIntentPublication: Sendable {
    public let reference: ChapterLocalIntentReference
    public let readSet: ChapterIntentReadSet
}

/// Portable immutable intent evidence with REQUIRED current Reader authority.
/// Durable authority must be explicitly configured; it is never inferred from
/// a directory scan, cached snapshot or publication file. No lock is granted.
public enum ChapterLocalIntentSnapshot {
    public static let maximumPayloadBytes = 128 * 1024
    private struct Envelope: Codable { let version: Int; let readSet: ChapterIntentReadSet }
    enum Event: Sendable { case beforeCommit, afterCommit, afterRead }
    typealias Checkpoint = @Sendable (Event) async throws -> Void

    /// Execute only inside the Reader process that owns the outbox.
    public static func publishCurrent(for request: ChapterRenderRequest, outbox: ChapterDemandOutbox,
                                      session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                                      directory: URL) async throws -> ChapterLocalIntentPublication {
        try await publishCurrent(for: request, outbox: outbox, session: session,
                                 gate: gate, directory: directory, checkpoint: { _ in })
    }
    static func publishCurrent(for request: ChapterRenderRequest, outbox: ChapterDemandOutbox,
                               session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                               directory: URL, checkpoint: @escaping Checkpoint) async throws -> ChapterLocalIntentPublication {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard session.accountPartition == request.accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard let readSet = try await outbox.wantedReadSet(for: request) else { throw ChapterLocalIntentError.incompleteIntent }
        let authority = ChapterReaderIntentAuthority(outbox: outbox, session: session, gate: gate)
        let bytes = try encode(.init(version: 1, readSet: readSet))
        let reference = try ChapterLocalIntentReference(identifier: hash(bytes))
        let task = Task.detached(priority: .utility) {
            try await ChapterImmutableBlob.publish(bytes, identifier: reference.identifier, directory: directory,
                maximumBytes: maximumPayloadBytes) {
                    try await checkpoint(.beforeCommit)
                    try await requireCurrent(readSet, authority: authority, session: session, gate: gate)
                }
            try await checkpoint(.afterCommit)
            try await requireCurrent(readSet, authority: authority, session: session, gate: gate)
            return ChapterLocalIntentPublication(reference: reference, readSet: readSet)
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await requireCurrent(readSet, authority: authority, session: session, gate: gate)
        return result
    }

    /// Worker supplies its OWN session and a trusted read-only Reader endpoint.
    /// Missing/offline/failed authority fails closed; there is no file-only fallback.
    public static func receive(_ reference: ChapterLocalIntentReference, request: ChapterRenderRequest,
                               requestingDevice: UUID, session: ChapterAccountSession,
                               gate: ChapterAccountSessionGate, authority: any ChapterIntentAuthority,
                               directory: URL) async throws -> ChapterIntentReadSet {
        try await receive(reference, request: request, requestingDevice: requestingDevice, session: session,
                          gate: gate, authority: authority, directory: directory, checkpoint: { _ in })
    }
    static func receive(_ reference: ChapterLocalIntentReference, request: ChapterRenderRequest,
                        requestingDevice: UUID, session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                        authority: any ChapterIntentAuthority, directory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChapterIntentReadSet {
        try request.validate(); try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        let task = Task.detached(priority: .utility) {
            let bytes = try ChapterImmutableBlob.read(reference.identifier, directory: directory, maximumBytes: maximumPayloadBytes)
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes), readSet = envelope.readSet
            guard envelope.version == 1, try encode(envelope) == bytes,
                  readSet.intent.request.accountPartition == request.accountPartition,
                  readSet.intent.deviceID == requestingDevice,
                  try readSet.intent.request.renderKey() == request.renderKey() else { throw ChapterLocalIntentError.invalidRecord }
            try await checkpoint(.afterRead)
            try await requireCurrent(readSet, authority: authority, session: session, gate: gate)
            return readSet
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await requireCurrent(result, authority: authority, session: session, gate: gate)
        return result
    }

    /// Recheck before each model work boundary and publication. This observation
    /// is instantaneous, not a lock/lease preventing a later Reader cancellation.
    public static func requireCurrent(_ readSet: ChapterIntentReadSet, authority: any ChapterIntentAuthority,
                                      session: ChapterAccountSession, gate: ChapterAccountSessionGate) async throws {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        guard session.accountPartition == readSet.intent.request.accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard try await authority.validateCurrent(readSet) else { throw ChapterLocalIntentError.staleIntent }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(envelope)
        guard bytes.count <= maximumPayloadBytes else { throw ChapterLocalIntentError.budget }
        return bytes
    }
}
