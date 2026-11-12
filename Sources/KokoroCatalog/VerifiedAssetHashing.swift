import CryptoKit
import Foundation
import Synchronization

/// Bounded parallel reads with ordered results. Every byte is still hashed on
/// every call; there is no validation cache. Public callers retain file order,
/// size policy, Cocoa errors, and cancellation at chunk boundaries.
package enum VerifiedAssetHashing {
    package struct File: Sendable {
        package let url: URL
        package let size: Int?
        package let sha256: String
        package init(url: URL, size: Int? = nil, sha256: String) {
            self.url = url; self.size = size; self.sha256 = sha256
        }
    }
    package static func validate(_ files: [File]) throws {
        let cancelled = Mutex(false)
        let width = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        // Small batches would serialize large graph weights separated by tiny
        // metadata files. Keep four active reads and at most 64 queued results.
        let batchSize = width * 16
        for start in stride(from: 0, to: files.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(files[start..<min(files.count, start + batchSize)])
            let results = Mutex<[Int: Result<Void, Error>]>([:])
            let group = DispatchGroup()
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = width
            queue.qualityOfService = .userInitiated
            for (index, file) in batch.enumerated() {
                group.enter()
                queue.addOperation {
                    let result = Result { try hash(file, cancelled: cancelled) }
                    results.withLock { $0[index] = result }
                    group.leave()
                }
            }
            do {
                for index in batch.indices {
                    // Joining in original order preserves the first file error.
                    while true {
                        try Task.checkCancellation()
                        if let result = results.withLock({ $0[index] }) { try result.get(); break }
                        _ = group.wait(timeout: .now() + .milliseconds(2))
                    }
                }
            } catch {
                cancelled.withLock { $0 = true }
                // A throwing synchronous call must not leave background file
                // descriptors/work alive after its owner retires the assets.
                group.wait()
                throw error
            }
            group.wait()
        }
    }
    private static func hash(_ file: File, cancelled: borrowing Mutex<Bool>) throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        if let size = file.size,
           (try file.url.resourceValues(forKeys: [.fileSizeKey])).fileSize != size { throw CocoaError(.fileReadCorruptFile) }
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
    }
}
