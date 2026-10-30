import Foundation
import CryptoKit

public enum ChapterLocalCompletionError: Error, Equatable { case invalidRecord, budget }

/// Complete Worker publication metadata, NOT decoded audio, playable state or
/// this Reader's demand acknowledgement. Producer epochs are never serialized.
public struct ChapterLocalCompletionReceipt: Sendable {
    public let readSet: ChapterIntentReadSet
    public let handoffReference: ChapterLocalHandoffReference
}

/// Deterministic, immutable lookup by the exact wanted read set. The host owns
/// Worker-only write/Reader-read transport authority; hashes do not authenticate
/// arbitrary writers. No directory scan or mutable Reader journal is used.
public enum ChapterLocalCompletion {
    public static let maximumPayloadBytes = 128 * 1024
    private struct Body: Codable {
        let version: Int
        let readSet: ChapterIntentReadSet
        let handoffReference: ChapterLocalHandoffReference
    }
    private struct Envelope: Codable { let body: Body; let checksum: String }
    package enum Event: Sendable { case beforeCommit, afterCommit, afterRead }
    package typealias Checkpoint = @Sendable (Event) async throws -> Void

    public static func lookupKey(for readSet: ChapterIntentReadSet) throws -> String {
        let bytes = try canonical(readSet)
        guard bytes.count <= maximumPayloadBytes else { throw ChapterLocalCompletionError.budget }
        return hash(bytes)
    }
    // Package-only: the native producer seam consumes a live joined Worker
    // result. External apps do not receive a public metadata-forging factory.
    package static func publish(readSet: ChapterIntentReadSet, handoffReference: ChapterLocalHandoffReference,
                                session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                                authority: any ChapterIntentAuthority, directory: URL,
                                producerFence: @escaping @Sendable () throws -> Void,
                                checkpoint: @escaping Checkpoint = { _ in }) async throws -> ChapterLocalCompletionReceipt {
        try producerFence()
        try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
        let key = try lookupKey(for: readSet), body = Body(version: 1, readSet: readSet, handoffReference: handoffReference)
        let bytes = try canonical(Envelope(body: body, checksum: hash(canonical(body))))
        guard bytes.count <= maximumPayloadBytes else { throw ChapterLocalCompletionError.budget }
        let task = Task.detached(priority: .utility) {
            try producerFence()
            try await ChapterImmutableBlob.publishCompletionPayload(bytes, key: key, directory: directory, maximumBytes: maximumPayloadBytes) {
                try await checkpoint(.beforeCommit)
                try producerFence()
                try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
                try producerFence()
            }
            try await checkpoint(.afterCommit)
            try producerFence()
            try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
            return ChapterLocalCompletionReceipt(readSet: readSet, handoffReference: handoffReference)
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try producerFence()
        try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
        return result
    }
    /// Metadata-only observation. nil means the exact receipt leaf is absent;
    /// missing/foreign roots, corrupt data and unavailable authority fail closed.
    public static func receiveIfPresent(for readSet: ChapterIntentReadSet, session: ChapterAccountSession,
                                        gate: ChapterAccountSessionGate, authority: any ChapterIntentAuthority,
                                        directory: URL) async throws -> ChapterLocalCompletionReceipt? {
        try await receiveIfPresent(for: readSet, session: session, gate: gate, authority: authority,
            directory: directory, checkpoint: { _ in })
    }
    package static func receiveIfPresent(for readSet: ChapterIntentReadSet, session: ChapterAccountSession,
                                         gate: ChapterAccountSessionGate, authority: any ChapterIntentAuthority,
                                         directory: URL, checkpoint: @escaping Checkpoint) async throws -> ChapterLocalCompletionReceipt? {
        try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
        let key = try lookupKey(for: readSet)
        let task = Task.detached(priority: .utility) { () async throws -> ChapterLocalCompletionReceipt? in
            guard let bytes = try ChapterImmutableBlob.readCompletionPayloadIfPresent(key, directory: directory, maximumBytes: maximumPayloadBytes)
            else { return nil }
            let value = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard value.body.version == 1, value.checksum == (try hash(canonical(value.body))),
                  try canonical(value) == bytes, try lookupKey(for: value.body.readSet) == key,
                  try canonical(value.body.readSet) == canonical(readSet) else { throw ChapterLocalCompletionError.invalidRecord }
            try await checkpoint(.afterRead)
            try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
            return .init(readSet: readSet, handoffReference: value.body.handoffReference)
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await ChapterLocalIntentSnapshot.requireCurrent(readSet, authority: authority, session: session, gate: gate)
        return result
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
