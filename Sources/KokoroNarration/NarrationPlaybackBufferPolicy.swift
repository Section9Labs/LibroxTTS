import Foundation

/// Bounds live narration work by the audio the listener still has queued.
/// Generate without artificial CPU delays while the buffer needs audio.
/// For long units, apply the decision at streaming frame boundaries. The host
/// owns playback, cancellation and permitted background time.
/// This policy never changes voices, sampling, chunking or audio.
public struct NarrationPlaybackBufferPolicy: Sendable {
    /// Thresholds are seconds of listening time, after applying playback rate.
    public static let resumeBelowSeconds: Double = 12
    public static let pauseAtSeconds: Double = 30
    private var filling = true

    public init() {}

    /// Call after a seek, book change or replacement of the playback queue.
    public mutating func reset() { filling = true }

    /// Check between streaming frames or before starting each unit. A whole unit
    /// can take the queue above the target; never cut its audio or alter its
    /// synthesis settings. Pending units include a currently streaming unit.
    /// `playbackRequested` includes initial buffering before audible playback.
    /// When false, cancel any in-flight render separately and stop scheduling.
    public mutating func shouldGenerate(
        bufferedAudioSeconds: Double,
        playbackRate: Double = 1,
        playbackRequested: Bool,
        hasPendingUnits: Bool = true
    ) -> Bool {
        guard playbackRequested, hasPendingUnits,
              bufferedAudioSeconds.isFinite, bufferedAudioSeconds >= 0,
              playbackRate.isFinite, playbackRate > 0 else {
            reset()
            return false
        }
        let remaining = bufferedAudioSeconds / playbackRate
        if remaining >= Self.pauseAtSeconds { filling = false }
        else if remaining <= Self.resumeBelowSeconds { filling = true }
        return filling
    }
}
