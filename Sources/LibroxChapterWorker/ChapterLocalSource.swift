import Foundation
import CryptoKit

public enum ChapterLocalSourceError: Error, Equatable { case invalidReference, invalidRecord, budget, storage }
public struct ChapterLocalSourceReference: Codable, Sendable, Equatable {
    public let identifier: String
    public init(identifier: String) throws {
        guard isDigest(identifier) else { throw ChapterLocalSourceError.invalidReference }
        self.identifier = identifier
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identifier: c.decode(String.self, forKey: .identifier))
    }
    private enum CodingKeys: String, CodingKey { case identifier }
}
/// Successfully published immutable source identity, not an intent, claim or
/// account credential. The journal persists only the reference, never this epoch.
public struct ChapterLocalSourcePublication: Sendable {
    public let reference: ChapterLocalSourceReference
    public let source: ChapterSourceIdentity
    public let accountPartition: String
}
public enum ChapterLocalSource {
    public static let maximumUTF16 = 131072
    public static let maximumUTF8 = 393216
    public static let maximumPayloadBytes = 2 * 1024 * 1024
    private struct Envelope: Codable {
        let version: Int
        let accountPartition: String
        let source: ChapterSourceIdentity
        let originalText: String
    }
    enum Event: Sendable { case beforeCommit, afterCommit, afterRead }
    typealias Checkpoint = @Sendable (Event) async throws -> Void

    /// Pure content identity; neither a publication nor a request acknowledgement.
    public static func contentReference(for submission: ChapterSubmission) throws -> ChapterLocalSourceReference {
        try .init(identifier: hash(encode(submission)))
    }
    public static func publish(_ submission: ChapterSubmission, gate: ChapterAccountSessionGate,
                               directory: URL) async throws -> ChapterLocalSourcePublication {
        try await publish(submission, gate: gate, directory: directory, checkpoint: { _ in })
    }
    static func publish(_ submission: ChapterSubmission, gate: ChapterAccountSessionGate, directory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChapterLocalSourcePublication {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        let bytes = try encode(submission), reference = try ChapterLocalSourceReference(identifier: hash(bytes))
        let task = Task.detached(priority: .utility) {
            try await ChapterImmutableBlob.publish(bytes, identifier: reference.identifier, directory: directory,
                maximumBytes: maximumPayloadBytes) {
                    try await checkpoint(.beforeCommit)
                    try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
                }
            try await checkpoint(.afterCommit)
            try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
            return ChapterLocalSourcePublication(reference: reference, source: submission.request.source,
                accountPartition: submission.request.accountPartition)
        }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return value
    }
    /// Worker supplies the expected admitted request and its own current session.
    /// This reads exact source, not an arbitrary reader book URL or database.
    public static func receive(_ reference: ChapterLocalSourceReference, request: ChapterRenderRequest,
                               session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                               directory: URL) async throws -> ChapterSubmission {
        try await receive(reference, request: request, session: session, gate: gate, directory: directory, checkpoint: { _ in })
    }
    static func receive(_ reference: ChapterLocalSourceReference, request: ChapterRenderRequest,
                        session: ChapterAccountSession, gate: ChapterAccountSessionGate, directory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChapterSubmission {
        try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == session.accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard request.source.utf16Length <= maximumUTF16 else { throw ChapterLocalSourceError.budget }
        try await gate.validate(session); try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            let bytes = try ChapterImmutableBlob.read(reference.identifier, directory: directory, maximumBytes: maximumPayloadBytes)
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 1, envelope.accountPartition == request.accountPartition,
                  envelope.source == request.source else { throw ChapterLocalSourceError.invalidRecord }
            let value = try ChapterSubmission(request: request, originalText: envelope.originalText, session: session)
            guard try encode(value) == bytes else { throw ChapterLocalSourceError.invalidRecord }
            try await checkpoint(.afterRead)
            try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
            return value
        }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        return value
    }
    private static func encode(_ submission: ChapterSubmission) throws -> Data {
        guard submission.originalText.utf16.count <= maximumUTF16, submission.originalText.utf8.count <= maximumUTF8
        else { throw ChapterLocalSourceError.budget }
        try submission.request.source.validate(text: submission.originalText)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Envelope(version: 1, accountPartition: submission.request.accountPartition,
            source: submission.request.source, originalText: submission.originalText))
        guard bytes.count <= maximumPayloadBytes else { throw ChapterLocalSourceError.budget }
        return bytes
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
