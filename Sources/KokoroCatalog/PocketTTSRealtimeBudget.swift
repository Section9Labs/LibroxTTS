import Foundation

/// Optional host policy for continuous listening. Begin at the user's requested
/// quality; lower only after measured generation cannot replenish the buffer.
/// This never changes an in-flight unit or the user's saved profile. Apply the
/// returned settings to the next unit BEFORE computing its cache identity.
public struct PocketTTSRealtimeBudget: Sendable {
    public let requested: PocketTTSSamplingOptions
    public private(set) var effective: PocketTTSSamplingOptions
    private var slowUnits = 0

    public init(requested: PocketTTSSamplingOptions) throws {
        try requested.validate()
        self.requested = requested
        effective = requested
    }

    /// Start a fresh measurement window when changing CPU/GPU backend, voice,
    /// language or playback speed. Prepared/offline renders need no adaptation.
    public mutating func reset() {
        effective = requested
        slowUnits = 0
    }

    /// Durations and buffer are audio seconds; playbackRate converts them to
    /// wall time. Ignore cached hits, failed/cancelled renders and other profiles.
    /// Two slow units plus less than 30 seconds of playable buffer are required
    /// before reducing steps. At one step the host must buffer/wait if still slow.
    @discardableResult
    public mutating func record(renderSeconds: Double, audioSeconds: Double,
                                bufferedAudioSeconds: Double, playbackRate: Double = 1,
                                renderedWith sampling: PocketTTSSamplingOptions) -> PocketTTSSamplingOptions {
        guard sampling == effective, renderSeconds.isFinite, renderSeconds > 0,
              audioSeconds.isFinite, audioSeconds > 0,
              bufferedAudioSeconds.isFinite, bufferedAudioSeconds >= 0,
              playbackRate.isFinite, playbackRate > 0 else { return effective }
        let playableSeconds = audioSeconds / playbackRate
        slowUnits = renderSeconds > playableSeconds * 0.9 ? slowUnits + 1 : 0
        guard slowUnits >= 2, bufferedAudioSeconds / playbackRate < 30,
              let next = [8, 4, 2, 1].first(where: { $0 < effective.samplerSteps }) else { return effective }
        effective.samplerSteps = next
        slowUnits = 0
        return effective
    }
}
