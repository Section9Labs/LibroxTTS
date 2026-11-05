import Foundation
import CloudKit
import Synchronization
import LibroxChapterWorker

public enum ChatterboxCloudServiceError: LocalizedError, Sendable {
    case closed, notReady, notFound, busy, staleIntent, interrupted
    public var errorDescription: String? {
        switch self {
        case .closed: "Narration has stopped. Enable this Mac to reconnect."
        case .notReady: "Waiting for a Mac to finish loading Chatterbox Multilingual."
        case .notFound: "This book has no preparation request on this device yet."
        case .busy: "Another narration operation is finishing. Try again shortly."
        case .staleIntent: "This preparation request changed. Open the book and try again."
        case .interrupted: "Preparation was interrupted. Completed audio is preserved."
        }
    }
}

/// Stops synchronously and joins the original operations before releasing any
/// role lock or file custody. A cancelled task is never treated as a joined one.
package final class ChatterboxCloudOperations: Sendable {
    private struct Entry: Sendable {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }
    private struct State: Sendable { var stopped = false; var entries: [UUID: Entry] = [:] }
    private let state = Mutex(State())
    package init() {}
    package func check() throws {
        try Task.checkCancellation()
        if state.withLock({ $0.stopped }) { throw ChatterboxCloudServiceError.closed }
    }
    package func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try check()
        let id = UUID()
        // The operation cannot start until ownership has been installed.
        let admission = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            for await _ in admission.stream { break }
            try self.check(); return try await operation()
        }
        let accepted = state.withLock { value in
            guard !value.stopped, value.entries.count < 48 else { return false }
            value.entries[id] = Entry(cancel: { task.cancel() }, join: { _ = await task.result })
            return true
        }
        if !accepted { task.cancel() }
        admission.continuation.yield(()); admission.continuation.finish()
        defer { _ = state.withLock { $0.entries.removeValue(forKey: id) } }
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        guard accepted else { throw ChatterboxCloudServiceError.busy }
        let value = try result.get(); try check(); return value
    }
    package func stop() {
        let entries = state.withLock { value in value.stopped = true; return Array(value.entries.values) }
        entries.forEach { $0.cancel() }
    }
    /// A publisher may advance the strict snapshot between its two reads.
    /// Retry the entire read under the same owned task; never weaken the fence
    /// or retry an account/intent revocation as if it were a network conflict.
    package func read<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await run {
            for attempt in 0..<4 {
                try self.check()
                do { return try await operation() }
                catch {
                    try self.check()
                    let transient: Bool
                    if let error = error as? ChapterDemandTransportError {
                        transient = [.conflict, .uncertain, .inconsistentSnapshot, .busy].contains(error)
                    } else if let error = error as? ChapterWorkerError { transient = error == .busy }
                    else { transient = false }
                    guard transient, attempt < 3 else { throw error }
                    try await Task.sleep(for: .milliseconds(100 * (1 << attempt)))
                }
            }
            throw ChapterDemandTransportError.conflict
        }
    }
    package func join() async {
        stop()
        let entries = state.withLock { Array($0.entries.values) }
        for entry in entries { await entry.join() }
    }
}

package struct ChatterboxCloudStockRecord: Codable, Sendable {
    let version: Int
    let modelSHA256, conditioningSHA256, rendererProfile: String
    package init(_ descriptor: ChatterboxStockVoiceDescriptor) {
        version = 1; modelSHA256 = descriptor.modelSHA256
        conditioningSHA256 = descriptor.conditioningSHA256; rendererProfile = descriptor.rendererProfile
    }
    package func descriptor() throws -> ChatterboxStockVoiceDescriptor {
        guard version == 1 else { throw ChapterWorkerError.invalidManifest }
        return try .init(modelSHA256: modelSHA256, conditioningSHA256: conditioningSHA256, rendererProfile: rendererProfile)
    }
}

/// Bounded immutable content cache. It never substitutes for current demand or
/// worker fences; every discovery still reads the live membership transaction.
private actor CloudBookMemo<Value: Sendable> {
    private var values: [String: (Value, Int)] = [:]
    private var order: [String] = []
    func get(_ key: String) -> Value? {
        guard let entry = values[key] else { return nil }
        order.removeAll { $0 == key }; order.append(key); return entry.0
    }
    func put(_ key: String, value: Value, bytes: Int) {
        guard bytes <= 16 * 1024 * 1024 else { return }
        values[key] = (value, bytes); order.removeAll { $0 == key }; order.append(key)
        while values.count > 32 || values.values.reduce(0, { $0 + $1.1 }) > 16 * 1024 * 1024 {
            values.removeValue(forKey: order.removeFirst())
        }
    }
}

/// All directories belong to ONE role and ONE account. A native worker and a
/// reader use different roots, including when both live inside the menu app.
package struct ChatterboxCloudBookConnection: Sendable {
    private let contentMemo = CloudBookMemo<ChatterboxBookEntryContent>()
    private let readSetMemo = CloudBookMemo<ChatterboxPreparedBookReadSet>()
    package let session: ChapterAccountSession
    package let gate: ChapterAccountSessionGate
    package let directory: ChapterCloudDirectory
    package let entries: ChapterCloudBookEntryTransport
    package let readSets: ChapterCloudBookReadSetTransport
    package let segments: ChapterCloudSegmentTransport
    package let work: ChapterCloudBookWorkTransport
    package let budget: ChapterArtifactStorageBudget
    package let sources, plans, contents, capture, custody, output: URL
    package init(container: CKContainer, account: ChapterCloudAccountIdentity,
                 session: ChapterAccountSession, gate: ChapterAccountSessionGate, root: URL,
                 policy: ChapterStorageBudgetPolicy,
                 authorize: @escaping @Sendable () async throws -> Void,
                 validateWorkerOwnership: @escaping @Sendable () async throws -> Void = {
                     throw ChatterboxCloudServiceError.notReady
                 }) throws {
        self.session = session; self.gate = gate
        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return url
        }
        sources = try folder("Sources"); plans = try folder("Plans"); contents = try folder("Content")
        capture = try folder("Transfer"); custody = try folder("Audio"); output = try folder("Output")
        budget = try .init(controlDirectory: contents,
            managedDirectories: [sources, plans, contents, capture, custody, output], policy: policy)
        directory = try .init(container: container, account: account, session: session, gate: gate, authorize: authorize)
        entries = try .init(container: container, account: account, session: session, gate: gate,
            captureStorage: capture, authorizeAssetTransfer: authorize)
        readSets = try .init(container: container, account: account, session: session, gate: gate,
            captureStorage: capture, authorizeAssetTransfer: authorize)
        segments = try .init(container: container, account: account, session: session, gate: gate,
            captureStorage: capture, custodyStorage: custody, authorizeAssetTransfer: authorize)
        work = try .init(container: container, account: account, session: session, gate: gate,
            authorizeControlTransfer: authorize, validateWorkerOwnership: validateWorkerOwnership)
    }
    package func content(_ set: ChatterboxPreparedBookReadSet, at index: Int) async throws -> ChatterboxBookEntryContent? {
        guard let identity = set.metadata.entries.first(where: { $0.chapterIndex == index })?.content else { return nil }
        if let cached = await contentMemo.get(identity.payloadSHA256) {
            try set.validate(cached, session: session); try await gate.validate(session); try Task.checkCancellation(); return cached
        }
        let bytes = try await entries.download(identity)
        let content = try ChatterboxBookEntryContent.decode(bytes, identity: identity, book: set.book,
            chapterIndex: index, session: session)
        try set.validate(content, session: session); try await gate.validate(session)
        await contentMemo.put(identity.payloadSHA256, value: content, bytes: bytes.count)
        return content
    }
    package func currentSets(scopeID: String) async throws -> [ChatterboxPreparedBookReadSet] {
        var sets: [ChatterboxPreparedBookReadSet] = []
        for identity in try await directory.readSets(scopeID: scopeID) {
            if let cached = await readSetMemo.get(identity.payloadSHA256) { sets.append(cached); continue }
            let metadata = try await readSets.download(identity)
            let set = try ChatterboxPreparedBookReadSet(metadata, session: session)
            await readSetMemo.put(identity.payloadSHA256, value: set, bytes: Int(identity.byteCount))
            sets.append(set)
        }
        try await gate.validate(session); return sets
    }
}

public struct ChatterboxCloudBookSummary: Identifiable, Sendable {
    public var id: String { scopeID }
    public let scopeID, title: String
    public let requested: Bool
    package init(scopeID: String, title: String, requested: Bool) {
        self.scopeID = scopeID; self.title = title; self.requested = requested
    }
}
