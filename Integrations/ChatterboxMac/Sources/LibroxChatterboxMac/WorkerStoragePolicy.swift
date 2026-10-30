#if os(macOS)
import Foundation
import LibroxChapterWorker
import ChatterboxMacAcousticAudit

/// Conservative retained-file admission envelope for the existing full-quality
/// pipeline. Codec sizes are checked AFTER native writes; this is NOT a
/// pre-write codec cap or an OS quota. Actual inventory is checked at boundaries
/// and after the exact producer joins before any successful Worker return.
public enum ChatterboxMacWorkerStoragePolicy {
    public static let maximumReceiptBytes = 8 * 1024 * 1024
    public static let maximumUnitCacheBytes = 64 * 1024 * 1024
    public static let maximumUnitScratchBytes = 120 * 24_000 * 4 + 48
    // Raw spool + encoded stage/final aliases + custody + publication + one
    // cache atomic-write temporary + both receipt aliases + metadata.
    public static let freshAdmissionBytes: UInt64 = UInt64(NativeFileAudioExport.maximumFrames) * 4
        + UInt64(NativeFileAudioExport.maximumEncodedBytes) * 4
        + UInt64(maximumUnitCacheBytes + maximumUnitScratchBytes + maximumReceiptBytes * 2 + ChapterLocalHandoff.maximumMetadataBytes)

    static func recoveryAdmissionBytes(_ manifest: ChapterArtifactManifest) throws -> UInt64 {
        guard manifest.audioByteCount > 0, manifest.audioByteCount <= NativeFileAudioExport.maximumEncodedBytes
        else { throw ChapterWorkerError.invalidManifest }
        return UInt64(manifest.audioByteCount) * 2 + UInt64(ChapterLocalHandoff.maximumMetadataBytes)
    }
}
#endif
