import Foundation
import Synchronization

/// A lease spanning engine awaits. Queue links and ownership change under one
/// mutex; continuations resume outside it. Nonthrowing retirement/settings join
/// even when cancelled. Only work that already checked cancellation opts in.
final class NarrationAdmission: Sendable {
    private enum Continuation {
        case joined(CheckedContinuation<Void, Never>)
        case cancellable(CheckedContinuation<Void, any Error>)
        func resume() {
            switch self { case .joined(let c): c.resume(); case .cancellable(let c): c.resume() }
        }
        func cancel() {
            guard case .cancellable(let c) = self else { preconditionFailure("Joined work cannot be cancelled") }
            c.resume(throwing: CancellationError())
        }
    }
    private struct Node {
        let continuation: Continuation
        var previous: UUID?
        var next: UUID?
    }
    private struct State {
        var held = false
        var first: UUID?
        var last: UUID?
        var nodes: [UUID: Node] = [:]
        mutating func remove(_ id: UUID) -> Continuation? {
            guard let node = nodes.removeValue(forKey: id) else { return nil }
            if let previous = node.previous { nodes[previous]?.next = node.next }
            else { first = node.next }
            if let next = node.next { nodes[next]?.previous = node.previous }
            else { last = node.previous }
            return node.continuation
        }
    }
    private final class Ticket: Sendable {
        let id = UUID()
        let cancelled = Mutex(false)
    }
    private enum Admission { case queued, admitted, cancelled }
    private let state = Mutex(State())
    var queuedCount: Int { state.withLock { $0.nodes.count } }

    private func enqueue(_ continuation: Continuation, id: UUID, ticket: Ticket? = nil) -> Admission {
        state.withLock { state in
            if ticket?.cancelled.withLock({ $0 }) == true { return .cancelled }
            guard state.held else { state.held = true; return .admitted }
            state.nodes[id] = Node(continuation: continuation, previous: state.last)
            if let last = state.last { state.nodes[last]?.next = id } else { state.first = id }
            state.last = id
            return .queued
        }
    }

    func acquire() async {
        await withCheckedContinuation { continuation in
            if enqueue(.joined(continuation), id: UUID()) == .admitted { continuation.resume() }
        }
    }

    func acquireCancellable() async throws {
        try Task.checkCancellation()
        let ticket = Ticket()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                switch enqueue(.cancellable(continuation), id: ticket.id, ticket: ticket) {
                case .queued: break
                case .admitted: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            // Release the ticket lock before taking the queue lock. Registration
            // may not have happened yet, or release may already have admitted it.
            ticket.cancelled.withLock { $0 = true }
            let removed = self.state.withLock { $0.remove(ticket.id) }
            removed?.cancel()
        }
        // A successful admission owns the lease even when cancellation wins
        // immediately afterward. Return it before throwing; never strand waiters.
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    func release() {
        let next = state.withLock { state -> Continuation? in
            precondition(state.held)
            if let first = state.first { return state.remove(first) }
            state.held = false
            return nil
        }
        next?.resume()
    }
}
