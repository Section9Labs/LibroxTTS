import Foundation

/// Loads `speech_emb.npy` — the (6563, 1024) Float32 speech-token embedding
/// table — and provides per-token row lookups.
///
/// Used in two places: assembling the padded `inputs_embeds` for the T3 prefill
/// (conditioning prompt tokens + the start-speech token) and the per-token
/// `inputs_embeds` of the decode loop (one row per generated token).
final class SpeechEmbedding: Sendable {
    let vocab: Int
    let hidden: Int
    private let table: [Float] // row-major: vocab * hidden

    init(contentsOf url: URL) throws {
        let (data, shape) = try NPYFloat32.read(url: url)
        guard shape.count == 2 else {
            throw ChatterboxError.npy("speech_emb expected 2-D, got shape \(shape)")
        }
        self.vocab = shape[0]
        self.hidden = shape[1]
        self.table = data
        guard table.count == vocab * hidden else {
            throw ChatterboxError.npy("speech_emb element count \(table.count) != \(vocab)*\(hidden)")
        }
    }

    /// Returns the `hidden`-length embedding row for `token`.
    func row(_ token: Int) -> [Float] {
        let start = token * hidden
        return Array(table[start..<start + hidden])
    }

    /// Appends the `hidden`-length embedding row for `token` to `out`.
    func appendRow(_ token: Int, to out: inout [Float]) {
        let start = token * hidden
        out.append(contentsOf: table[start..<start + hidden])
    }
}
