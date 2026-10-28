import Foundation

/// Cross-chunk pipeline overlap (issue #22): decode chunk N+1 on the **ANE**
/// concurrently with synth of chunk N on the **GPU**. Chunks are independent
/// (each `backend.generate` makes a fresh `MLState`; `SynthRunner` holds no
/// cross-call state) and the two legs use different silicon, so they overlap for
/// free at the orchestration layer. This file holds the producer→consumer
/// hand-off; the wiring lives in `ChatterboxCoreMLModel.produce`.

/// A decode result tagged with its chunk position, handed from the decode task
/// (ANE) to the synth task (GPU). `Sendable`: `T3Result` + `Conditionals` are
/// value types. The decode is fully finished (prefill → loop → state dropped)
/// before its `DecodedChunk` is sent, so nothing here aliases an `MLState`.
struct DecodedChunk: Sendable {
    let index: Int
    let result: T3Result
    let conds: Conditionals          // captured per call (voice can vary); Sendable
}

/// Bounded FIFO hand-off between the single decode producer and the single synth
/// consumer. `capacity` (1–2) bounds memory: at most `capacity` decoded-but-not-
/// synthed chunks are buffered, and `send` suspends the producer while full
/// (true backpressure → the decoder cannot race arbitrarily far ahead of synth).
///
/// **Single-producer / single-consumer only.** Exactly one task calls
/// `send`/`finish`/`fail` (decode) and exactly one calls `receive` (synth), so at
/// most one `pendingSend` and one `pendingReceive` are ever outstanding — that is
/// what makes the lone-continuation slots safe. The actor serializes all state.
///
/// Ordering is automatic: the producer enqueues strictly in chunk order, the
/// buffer is FIFO, and a single consumer drains it → audio emerges `0,1,2,…`.
///
/// Why not `AsyncThrowingStream`: its continuation buffer is unbounded, so a fast
/// decoder would stack token arrays without backpressure. Why not
/// `swift-async-algorithms` `AsyncChannel`: it would add a dependency for one small
/// type. Hence this hand-rolled actor.
actor BoundedChunkChannel {
    private var buffer: [DecodedChunk] = []
    private var finished = false
    private var failure: Error?
    private let capacity: Int
    private var pendingSend: CheckedContinuation<Void, Never>?
    private var pendingReceive: CheckedContinuation<DecodedChunk?, Error>?

    init(capacity: Int = 2) { self.capacity = max(1, capacity) }

    /// Enqueue one decoded chunk, suspending the (single) producer while the
    /// buffer is full. Returns early — dropping the chunk — once the channel has
    /// been finished or failed (the producer is unwinding anyway).
    func send(_ chunk: DecodedChunk) async {
        // Wait for room (or shutdown). Invariant: a pending receiver implies an
        // empty buffer, so while one is waiting `buffer.count >= capacity` is
        // false (capacity ≥ 1) and the loop doesn't block.
        while buffer.count >= capacity && failure == nil && !finished {
            await withCheckedContinuation { pendingSend = $0 }
        }
        if finished || failure != nil { return }
        // Re-check for a waiting consumer AFTER the wait: a receiver may have
        // registered `pendingReceive` while we were blocked (the buffer then
        // drained empty). Hand off directly; only buffer when none is waiting.
        // Buffering instead of handing off here would be a lost-wakeup bug — the
        // consumer would sleep forever on a chunk that's sitting in the buffer.
        if let c = pendingReceive {
            pendingReceive = nil
            c.resume(returning: chunk)
        } else {
            buffer.append(chunk)
        }
    }

    /// Signal end-of-stream after the last chunk. Wakes a waiting consumer with
    /// `nil`. Idempotent enough for the single-producer contract.
    func finish() {
        finished = true
        pendingReceive?.resume(returning: nil); pendingReceive = nil
    }

    /// Abort both sides with `error`. Wakes a suspended consumer (throws) and a
    /// suspended producer (so it unwinds without appending). First error wins.
    func fail(_ error: Error) {
        if failure == nil { failure = error }
        pendingReceive?.resume(throwing: error); pendingReceive = nil
        pendingSend?.resume(); pendingSend = nil
    }

    /// Dequeue the next chunk in FIFO order, suspending the (single) consumer
    /// while empty. Returns `nil` once finished and drained; throws if failed.
    /// A failure takes precedence over any still-buffered chunks (we abandon them
    /// — the pipeline is unwinding).
    func receive() async throws -> DecodedChunk? {
        if let e = failure { throw e }
        if !buffer.isEmpty {
            let head = buffer.removeFirst()
            pendingSend?.resume(); pendingSend = nil   // a slot freed → wake producer
            return head
        }
        if finished { return nil }
        return try await withCheckedThrowingContinuation { pendingReceive = $0 }
    }
}
