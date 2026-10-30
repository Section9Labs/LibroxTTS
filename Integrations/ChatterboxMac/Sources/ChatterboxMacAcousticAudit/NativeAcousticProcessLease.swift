#if os(macOS)
import Foundation

/// Dedicated-worker safeguard for upstream global MLX RNG. The lock protects
/// only the token; no model/tensor crosses it. Until a key-local vocoder is
/// qualified, two native acoustic actors may not coexist in one process.
final class NativeAcousticProcessLease: @unchecked Sendable {
    static let shared = NativeAcousticProcessLease()
    private let lock = NSLock()
    private var owner: UUID?
    func acquire() throws -> UUID {
        try lock.withLock {
            guard owner == nil else { throw AcousticInventoryError.unsafeResource }
            let token = UUID(); owner = token; return token
        }
    }
    func release(_ token: UUID) {
        lock.withLock { if owner == token { owner = nil } }
    }
}
#endif
