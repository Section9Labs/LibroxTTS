#if os(macOS)
import Foundation
import CryptoKit
import LibroxChatterbox
import LibroxChapterWorker
import LibroxChatterboxPlanning
import KokoroNarration
import ChatterboxMacAcousticAudit

struct MacChapterAuthorization: Sendable {
    let session: ChapterAccountSession
    let gate: ChapterAccountSessionGate
    let renderKey: String?
    let admission: (@Sendable () async throws -> Void)?
    init(session: ChapterAccountSession, gate: ChapterAccountSessionGate, renderKey: String? = nil,
         admission: (@Sendable () async throws -> Void)? = nil) {
        self.session = session; self.gate = gate; self.renderKey = renderKey; self.admission = admission
    }
    func validate() async throws {
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
        try await admission?()
        try Task.checkCancellation(); try await gate.validate(session); try Task.checkCancellation()
    }
}

extension ChatterboxMacChapterRequest {
    static func hash(_ data: Data) -> String { hashDigest(SHA256.hash(data: data)) }
    static func hashDigest<S: Sequence>(_ digest: S) -> String where S.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
    func expressionIdentity() throws -> String {
        expressionSHA256
    }
    func synthesisIdentity(rendererProfile: String) throws -> String {
        try canonicalSynthesisIdentity(rendererProfile: rendererProfile)
    }
    func deliveryIdentity(rendererProfile: String) throws -> String {
        struct Delivery: Encodable { let revision, synthesis, codec: String }
        return try Self.hash(Self.canonical(Delivery(revision: "mac-standard-chapter-delivery-1",
            synthesis: synthesisIdentity(rendererProfile: rendererProfile), codec: delivery.rawValue)))
    }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// SDK-created binding, not a host-assembled recipe. Account lifecycle remains
/// with the service/host gate; the renderer never discovers or opens an account.
public struct ChatterboxMacChapterBinding: Sendable {
    public let submission: ChapterSubmission
    let localRequest: ChatterboxMacChapterRequest
    let rendererID: UUID
    let settingsSHA256: String

    init(source: ChapterSourceIdentity, localRequest: ChatterboxMacChapterRequest,
         rendererID: UUID, backend: any ResidentChapterBackend, session: ChapterAccountSession) throws {
        let descriptor = try ChatterboxStockVoiceDescriptor(modelSHA256: backend.modelSHA256,
            conditioningSHA256: backend.conditioningSHA256, rendererProfile: backend.profile)
        submission = try descriptor.prepareChapter(source: source, options: localRequest, session: session).submission
        self.localRequest = localRequest; self.rendererID = rendererID
        settingsSHA256 = try localRequest.deliveryIdentity(rendererProfile: backend.profile)
    }

    /// Verifies the source/recipe/decoded export, privately copies it, and returns
    /// the existing account-bound playback custody. A URL alone is never playable.
    /// Caller cancels and joins this operation before relinquishing its worker.
    public func adopt(_ artifact: ChatterboxMacChapterArtifact, gate: ChapterAccountSessionGate,
                      storageDirectory: URL) async throws -> ChapterLocalArtifact {
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        let receipt = artifact.receipt, request = submission.request
        guard receipt.revision == "mac-local-chapter-2", receipt.sourceSHA256 == request.source.textSHA256,
              receipt.binding?.renderKey == (try request.renderKey()),
              receipt.binding?.accountPartition == submission.session.accountPartition,
              receipt.binding?.epoch == submission.session.epoch,
              receipt.sourceUTF16Length == request.source.utf16Length, receipt.rendererProfile == request.recipe.rendererProfile,
              receipt.settingsSHA256 == settingsSHA256, receipt.codecRevision == request.effectiveDelivery.codecRevision,
              artifact.audioFile.path == receipt.export.path, receipt.export.frameCountMatches,
              receipt.export.frames > 0, receipt.export.bytes > 0,
              receipt.export.codec == (request.effectiveDelivery == .smaller ? NativeAudioExport.Codec.aac64.rawValue : NativeAudioExport.Codec.alac24.rawValue) else {
            throw ChapterWorkerError.invalidManifest
        }
        let manifest = try ChapterArtifactManifest(renderKey: request.renderKey(), audioSHA256: receipt.export.sha256,
            audioByteCount: Int64(receipt.export.bytes), decodedFrameCount: receipt.export.frames,
            codecRevision: receipt.codecRevision, units: receipt.units)
        try manifest.validateCompleteSourceMap(text: submission.originalText, for: request)
        let result = try await ChapterLocalArtifact.adopt(download: artifact.audioFile, request: request,
            manifest: manifest, originalText: submission.originalText, session: submission.session,
            gate: gate, storageDirectory: storageDirectory)
        try Task.checkCancellation(); try await gate.validate(submission.session); try Task.checkCancellation()
        return result
    }
}
#endif
