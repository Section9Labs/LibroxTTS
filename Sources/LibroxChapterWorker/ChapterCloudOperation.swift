import Foundation
import CloudKit
import Synchronization

/// One native operation stays owned until Foundation completion, including
/// cancellation. Asset callbacks must privately capture staging files in their
/// result blocks; retaining CKRecord/fileURL alone is not file custody.
enum ChapterCloudOperation {
    static func run<Value: Sendable>(_ operation: CKDatabaseOperation, database: CKDatabase,
                                     configure: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        operation.qualityOfService = .utility
        let outcome = Mutex<Result<Value, Error>?>(nil)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                configure { result in outcome.withLock { if case .none = $0 { $0 = result } } }
                operation.completionBlock = { [weak operation] in
                    let value = outcome.withLock { stored in
                        let value = stored; stored = nil
                        return value ?? .failure(operation?.isCancelled == true ? CancellationError() : ChapterDemandTransportError.uncertain)
                    }
                    continuation.resume(with: value)
                }
                database.add(operation)
                if Task.isCancelled { operation.cancel() }
            }
        } onCancel: { operation.cancel() }
    }
}
