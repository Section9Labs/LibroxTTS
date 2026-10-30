import Foundation
import CryptoKit
import LibroxChapterWorker

/// Reader-owned immutable portable options. A file is not authoritative demand.
/// The future worker must observe current wanted intent and rebind the decoded
/// plan against its actual resident backend before starting any inference.
public enum ChatterboxLocalRenderPlan {
    public static let maximumPayloadBytes = 4 * 1024 * 1024
    private struct Envelope: Codable {
        let version: Int
        let accountPartition, renderKey: String
        let sourceReference: ChapterLocalSourceReference
        let plan: Data
    }
    enum Event: Sendable { case beforeCommit, afterCommit, afterRead }
    typealias Checkpoint = @Sendable (Event) async throws -> Void

    public static func publish(_ plan: ChatterboxChapterRenderPlan, submission: ChapterSubmission,
                               source: ChapterLocalSourcePublication, gate: ChapterAccountSessionGate,
                               directory: URL) async throws -> ChapterLocalRenderPlanPublication {
        try await publish(plan, submission: submission, source: source, gate: gate,
                          directory: directory, checkpoint: { _ in })
    }
    static func publish(_ plan: ChatterboxChapterRenderPlan, submission: ChapterSubmission,
                        source: ChapterLocalSourcePublication, gate: ChapterAccountSessionGate,
                        directory: URL, checkpoint: @escaping Checkpoint) async throws -> ChapterLocalRenderPlanPublication {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        guard source.accountPartition == submission.request.accountPartition,
              source.reference == (try ChapterLocalSource.contentReference(for: submission)) else {
            throw ChatterboxChapterRenderPlanError.sourceMismatch
        }
        try validate(plan, submission: submission)
        let renderKey = try submission.request.renderKey()
        let bytes = try encode(Envelope(version: 1, accountPartition: submission.request.accountPartition,
            renderKey: renderKey, sourceReference: source.reference, plan: plan.encoded()))
        let reference = try ChapterLocalRenderPlanReference(identifier: hash(bytes))
        let task = Task.detached(priority: .utility) {
            try await ChapterImmutableBlob.publish(bytes, identifier: reference.identifier, directory: directory,
                maximumBytes: maximumPayloadBytes) {
                    try await checkpoint(.beforeCommit)
                    try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
                }
            try await checkpoint(.afterCommit)
            try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
            return ChapterLocalRenderPlanPublication(reference: reference, sourceReference: source.reference,
                accountPartition: submission.request.accountPartition, renderKey: renderKey)
        }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return value
    }

    /// Requires source already admitted under the receiver's OWN current epoch.
    /// This returns exact options only; it never binds or starts a renderer.
    public static func receive(_ reference: ChapterLocalRenderPlanReference, submission: ChapterSubmission,
                               gate: ChapterAccountSessionGate, directory: URL) async throws -> ChatterboxChapterRenderPlan {
        try await receive(reference, submission: submission, gate: gate, directory: directory, checkpoint: { _ in })
    }
    static func receive(_ reference: ChapterLocalRenderPlanReference, submission: ChapterSubmission,
                        gate: ChapterAccountSessionGate, directory: URL,
                        checkpoint: @escaping Checkpoint) async throws -> ChatterboxChapterRenderPlan {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            let bytes = try ChapterImmutableBlob.read(reference.identifier, directory: directory, maximumBytes: maximumPayloadBytes)
            let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
            guard envelope.version == 1, envelope.accountPartition == submission.request.accountPartition,
                  envelope.renderKey == (try submission.request.renderKey()),
                  envelope.sourceReference == (try ChapterLocalSource.contentReference(for: submission)),
                  try encode(envelope) == bytes else { throw ChatterboxChapterRenderPlanError.invalidPlan }
            let plan = try ChatterboxChapterRenderPlan.decode(envelope.plan, source: submission.originalText)
            try validate(plan, submission: submission)
            try await checkpoint(.afterRead)
            try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
            return plan
        }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return value
    }
    package static func validate(_ plan: ChatterboxChapterRenderPlan, submission: ChapterSubmission) throws {
        let options = try plan.restore(source: submission.originalText), recipe = submission.request.recipe
        guard options.language == recipe.language, options.delivery == submission.request.effectiveDelivery,
              options.expressionSHA256 == recipe.expressionSHA256,
              try options.canonicalSynthesisIdentity(rendererProfile: recipe.rendererProfile) == recipe.synthesisOptionsSHA256,
              recipe.seedPolicy == "fixed-per-unit-1:\(options.seed)", recipe.watermarkRevision == "disabled-1"
        else { throw ChatterboxChapterRenderPlanError.recipeMismatch }
        // The complete options fingerprint is checked even for cache reuse.
        // Actual model/conditioning/backend qualification still precedes inference.
    }
    private static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private static func encode(_ envelope: Envelope) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(envelope)
        guard bytes.count <= maximumPayloadBytes else { throw ChatterboxChapterRenderPlanError.budget }
        return bytes
    }
}
