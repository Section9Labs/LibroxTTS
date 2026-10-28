import Foundation

/// Single producer / single consumer only. The channel holds at most two decoded
/// values; the producer can additionally own one value awaiting a free slot.
/// No audio is queued here. Shutdown wakes both continuation slots.
actor BoundedBatchChannel<Value: Sendable> {
    private let capacity: Int
    private var buffer: [Value] = []
    private var finished = false
    private var failure: Error?
    private var sender: CheckedContinuation<Void, Never>?
    private var receiver: CheckedContinuation<Value?, Error>?

    init(capacity: Int) {
        precondition((1...2).contains(capacity))
        self.capacity = capacity
    }

    func send(_ value: Value) async throws {
        try Task.checkCancellation()
        while buffer.count >= capacity && failure == nil && !finished {
            await withCheckedContinuation { sender = $0 }
        }
        if let failure { throw failure }
        guard !finished else { throw CancellationError() }
        try Task.checkCancellation()
        if let waiting = receiver {
            receiver = nil
            waiting.resume(returning: value)
        } else {
            buffer.append(value)
        }
    }

    func receive() async throws -> Value? {
        try Task.checkCancellation()
        if let failure { throw failure }
        if !buffer.isEmpty {
            let value = buffer.removeFirst()
            sender?.resume(); sender = nil
            return value
        }
        if finished { return nil }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func finish() {
        finished = true
        receiver?.resume(returning: nil); receiver = nil
        sender?.resume(); sender = nil
    }

    func fail(_ error: Error) {
        if failure == nil { failure = error }
        buffer.removeAll()
        receiver?.resume(throwing: failure!); receiver = nil
        sender?.resume(); sender = nil
    }
}

/// Structured tasks join before returning, including error and cancellation.
/// Cancellation cannot interrupt an in-flight synchronous Core ML call, but it
/// wakes channel waits immediately and is checked before the next piece of work.
enum BoundedBatchPipeline<Value: Sendable> {
    static func run(
        capacity: Int = 2,
        produce: @escaping @Sendable (BoundedBatchChannel<Value>) async throws -> Void,
        consume: @escaping @Sendable (Value) async throws -> Void
    ) async throws {
        let channel = BoundedBatchChannel<Value>(capacity: capacity)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask(priority: .userInitiated) {
                    do {
                        try await produce(channel)
                        await channel.finish()
                    } catch {
                        await channel.fail(error)
                        throw error
                    }
                }
                group.addTask(priority: .utility) {
                    do {
                        while let value = try await channel.receive() {
                            try Task.checkCancellation()
                            try await consume(value)
                        }
                    } catch {
                        await channel.fail(error)
                        throw error
                    }
                }
                // Observe failure before waiting for a sibling outside the channel.
                do { while try await group.next() != nil {} }
                catch {
                    group.cancelAll()
                    await channel.fail(error)
                    throw error
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await channel.fail(CancellationError()) }
        }
    }
}
