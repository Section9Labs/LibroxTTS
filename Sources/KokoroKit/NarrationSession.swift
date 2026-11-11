import Foundation
import KokoroNarration
import LibroxCTNative

/// Published only after a successful load/configuration. Exactly one engine
/// belongs to a loaded identity; retirement joins that engine before clearing it.
struct NarrationSession {
    enum Engine {
        case max(any NarrationMaxBackend)
        case plus(CTEngine, CTEngine.Backend)
        case basic(KokoroEngine)
    }
    let selection: NarrationModel
    let directory: URL
    let repositoryID: String
    var engine: Engine
}
