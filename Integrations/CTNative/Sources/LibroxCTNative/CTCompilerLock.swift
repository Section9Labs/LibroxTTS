import Darwin
import Foundation

/// Shared legacy lock excludes older SDKs using the global exclusive lock.
/// Per-key exclusive locks serialize matching generations while unrelated keys
/// can compile together. Waiting remains cancellable despite the synchronous API.
enum CTCompilerLock {
    static func withLock<T>(root: URL, key: String, onWait: @Sendable () -> Void = {},
                            _ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        func descriptor(_ name: String) throws -> Int32 {
            let value = open(root.appendingPathComponent(name).path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard value >= 0 else { throw CTError.invalidAssets("compiler cache lock") }
            return value
        }
        func acquire(_ descriptor: Int32, _ mode: Int32) throws {
            while flock(descriptor, mode | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw CTError.invalidAssets("compiler cache lock") }
                try Task.checkCancellation()
                onWait()
                Thread.sleep(forTimeInterval: 0.01)
            }
            try Task.checkCancellation()
        }
        let legacy = try descriptor(".compile.lock")
        defer { close(legacy) }
        try acquire(legacy, LOCK_SH)
        defer { flock(legacy, LOCK_UN) }
        let keyed = try descriptor(".compile-" + key + ".lock")
        defer { close(keyed) }
        try acquire(keyed, LOCK_EX)
        defer { flock(keyed, LOCK_UN) }
        return try body()
    }
}
