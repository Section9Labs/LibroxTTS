import Foundation
import KokoroPronunciation

extension BookNarrationUnit {
    /// A text-native renderer supplies its own tokenizer and persistent voice IDs.
    /// Source ranges still belong to the unchanged book; no Kokoro voice is selected.
    public init(sourceText: String, sourceRange: NSRange, narratorID: String,
                boundaryAfter: NarrationBoundary = .sentence,
                role: DialogueTimingRole = .unknown, speakerID: String? = nil) {
        self.init(text: sourceText, range: sourceRange, voiceID: narratorID,
                  phonemes: "", boundaryAfter: boundaryAfter)
        self.role = role; self.speakerID = speakerID
    }
}
