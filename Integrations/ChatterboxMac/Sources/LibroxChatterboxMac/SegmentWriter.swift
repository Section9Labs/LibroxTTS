#if os(macOS)
import Foundation
import Darwin
import LibroxChapterWorker
import LibroxChatterbox
import ChatterboxMacAcousticAudit

/// Actual completed native export plus exact source/frame metadata. This is a
/// producer file, NOT Reader custody, a CloudKit receipt or chapter completion.
public struct ChatterboxMacSegmentExport: Sendable {
    public let audioFile, manifestFile: URL
    public let manifest: ChapterSegmentManifest
    public let pcmSHA256: String
    public let export: NativeAudioExportReport
}

actor ResidentSegmentWriter {
    let cacheDirectory: URL
    private let submission: ChapterSubmission
    private let directory: URL
    private var prefix: ChapterSegmentPrefix
    private var generation: UUID?
    private var failed = false
    private var finished = false
    private var metadataBytes = 0
    init(submission: ChapterSubmission, directory: URL) throws {
        try submission.request.source.validate(text: submission.originalText)
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw ChatterboxMacRendererError.storage }
        let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw ChatterboxMacRendererError.storage }
        let job = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = job; self.submission = submission
        prefix = try .init(request: submission.request, originalText: submission.originalText)
        cacheDirectory = job.appendingPathComponent("UnitCache")
    }
    func append(_ passage: ChatterboxPreparedPassage,
                receive: @Sendable (ChatterboxMacSegmentExport) async throws -> Void) async throws {
        guard !failed, !finished else { throw ChatterboxMacRendererError.closed }
        do {
            try Task.checkCancellation()
            guard passage.index == prefix.segmentCount,
                  generation == nil || generation == passage.generationID,
                  let context = passage.unit.request.sourceContext,
                  context.range.location >= prefix.sourceEnd else { throw ChatterboxMacRendererError.invalidPassage }
            let end = NSMaxRange(context.range), start = prefix.sourceEnd
            let job = directory.appendingPathComponent(String(format: "segment-%04d", prefix.segmentCount), isDirectory: true)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let spool = try ChapterPCMSpool(source: submission.originalText, directory: job,
                coverageStart: start, firstPassageIndex: passage.index)
            try await spool.append(passage)
            let pcm = try await spool.finish(coverageEnd: end)
            guard pcm.frames <= ChapterSegmentManifest.maximumFrames else { throw ChatterboxMacRendererError.invalidPassage }
            let audioFile = job.appendingPathComponent("audio.m4a")
            let codec: NativeAudioExport.Codec = submission.request.effectiveDelivery == .smaller ? .aac64 : .alac24
            let producer = Task.detached(priority: .userInitiated) {
                try NativeFileAudioExport.write(rawPCM: pcm.file, frames: pcm.frames, pcmSHA256: pcm.pcmSHA256,
                                                to: audioFile, codec: codec)
            }
            // Exact original encoder task is joined on success, failure and
            // cancellation; no detached publication survives this append call.
            let encoded = try await withTaskCancellationHandler { try await producer.value } onCancel: { producer.cancel() }
            try Task.checkCancellation()
            let audio = ChapterArtifactManifest(renderKey: try submission.request.renderKey(), audioSHA256: encoded.sha256,
                audioByteCount: Int64(encoded.bytes), decodedFrameCount: pcm.frames,
                codecRevision: submission.request.effectiveDelivery.codecRevision, units: pcm.units)
            let manifest = try ChapterSegmentManifest(request: submission.request, segmentIndex: prefix.segmentCount,
                previousSegmentSHA256: prefix.tailSHA256, sourceRange: .init(offset: start, length: end - start),
                chapterStartFrame: prefix.decodedFrameCount, audio: audio, originalText: submission.originalText)
            let bytes = try manifest.encoded(), manifestFile = job.appendingPathComponent("segment.json")
            try writeMetadata(bytes, to: manifestFile)
            try prefix.append(manifest); generation = passage.generationID
            try Task.checkCancellation()
            try await receive(.init(audioFile: audioFile, manifestFile: manifestFile, manifest: manifest,
                                     pcmSHA256: pcm.pcmSHA256, export: encoded))
            try Task.checkCancellation()
        } catch { failed = true; throw error }
    }
    func finish() throws -> ChapterSegmentCompletionSeal {
        guard !failed, !finished else { throw ChatterboxMacRendererError.closed }
        try Task.checkCancellation()
        let seal = try prefix.completionSeal()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writeMetadata(encoder.encode(seal), to: directory.appendingPathComponent("chapter-seal.json"))
        try Task.checkCancellation(); finished = true
        return seal
    }
    private func writeMetadata(_ data: Data, to url: URL) throws {
        guard data.count <= ChatterboxMacWorkerStoragePolicy.maximumReceiptBytes - metadataBytes else { throw ChatterboxMacRendererError.storage }
        try Task.checkCancellation()
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatterboxMacRendererError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard fchmod(fd, 0o400) == 0 else { throw ChatterboxMacRendererError.storage }
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ChatterboxMacRendererError.storage }; defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw ChatterboxMacRendererError.storage }
        metadataBytes += data.count
    }
}
#endif
