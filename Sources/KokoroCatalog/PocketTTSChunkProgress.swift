import Foundation

/// A successfully generated text chunk and its interval in the emitted 24 kHz
/// mono PCM. This is chunk alignment, not word alignment. Frames may already
/// have been consumed when this arrives. Failed/cancelled chunks emit no event.
public struct PocketTTSChunkProgress: Equatable, Sendable {
    public let text: String
    public let startSample: Int
    public let endSample: Int

    public init(text: String, startSample: Int, endSample: Int) {
        self.text = text
        self.startSample = startSample
        self.endSample = endSample
    }
}
