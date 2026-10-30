import Foundation
import CryptoKit
import Darwin

public enum ChapterOutboxError: Error, Equatable {
    case closed, alreadyOpen, corrupt, budgetExceeded, storage, ambiguousWrite, unsupportedPolicy
}

/// A per-device local demand, not a CloudKit claim or acknowledgement.
public struct ChapterDemandIntent: Codable, Sendable, Equatable {
    public let request: ChapterRenderRequest
    public let deviceID: UUID
    public let revision: UInt64
    public let wanted: Bool
}
public struct ChapterConfirmedDemand: Sendable, Equatable {
    public let intent: ChapterDemandIntent
    public let serverRevision: ChapterServerRevision
}
/// A recovery identity, not a delivery acknowledgement or playable handle.
/// Re-adopt with exact source and the receiver's current account session/gate.
public struct ChapterRetainedHandoff: Sendable, Equatable {
    public let request: ChapterRenderRequest
    public let reference: ChapterLocalHandoffReference
    public let recordedAtIntentRevision: UInt64
}
/// Reader-owned durable intent/source pair. This snapshot does not claim work,
/// acknowledge delivery or authorize an account; worker admission remains separate.
public struct ChapterStoredSubmission: Sendable, Equatable {
    public let intent: ChapterDemandIntent
    public let sourceReference: ChapterLocalSourceReference
    public let renderPlanReference: ChapterLocalRenderPlanReference?
}
/// Live Reader-only optimistic admission. Not a durable intent, epoch grant or
/// portable Worker authority. Another intent command invalidates this token.
public struct ChapterDemandAdmission: Sendable {
    fileprivate let owner, commandStamp: UUID
    fileprivate let request: ChapterRenderRequest
    fileprivate let renderKey: String
    fileprivate let priorIntent: ChapterDemandIntent?
}

/// Crash-safe local intent journal. It never renders, uploads, claims work or
/// marks an audio asset ready. A transport must reconcile a pending revision
/// with conditional server state before acknowledging that exact revision.
/// Open off the UI actor; one process/actor owns each account/device journal.
public actor ChapterDemandOutbox {
    public static let maximumEntries = 8192
    public static let maximumJournalBytes = 32 * 1024 * 1024
    private struct StoredHandoff: Codable, Equatable {
        let reference: ChapterLocalHandoffReference
        let recordedAtIntentRevision: UInt64
    }
    private struct Entry: Codable, Equatable {
        let intent: ChapterDemandIntent
        var pending: Bool
        var serverRevision: String? = nil
        var handoff: StoredHandoff? = nil
        var sourceReference: ChapterLocalSourceReference? = nil
        var renderPlanReference: ChapterLocalRenderPlanReference? = nil
    }
    private struct Journal: Codable {
        let version: Int
        let partition: String
        let deviceID: UUID
        let entries: [String: Entry]
        let checksum: String
        var authority: ChapterDurableIntentDescriptor? = nil
    }
    private struct Loaded { let entries: [String: Entry]; let authority: ChapterDurableIntentDescriptor? }
    private struct AuthorityChecksum: Encodable { let entries: [String: Entry]; let authority: ChapterDurableIntentDescriptor }
    private final class Ownership: Sendable {
        let directory: Int32
        let lock: Int32
        init(directory: Int32, lock: Int32) { self.directory = directory; self.lock = lock }
        deinit { Darwin.close(lock); Darwin.close(directory) }
    }
    public let accountPartition: String
    public let deviceID: UUID
    private var ownership: Ownership?
    private var entries: [String: Entry]
    private let admissionOwner = UUID()
    private var admissionCommandStamp = UUID()
    private var uncertain = false
    private var authorityBinding: ChapterDurableIntentDescriptor?
    private var headWriter: ChapterIntentHeadWriter?
    private var authorityReady = true
    private var authorityFaultForTesting: (@Sendable (AuthorityEvent) throws -> Void)?
    enum AuthorityEvent: Sendable { case afterBlocked, afterJournal, afterArchive, afterReady }
    // Exact crash boundary exercised by tests; no production injection API.
    private var afterRenameForTesting: (@Sendable () throws -> Void)?

    public init(directory: URL, accountPartition: String, deviceID: UUID) throws {
        try self.init(directory: directory, accountPartition: accountPartition, deviceID: deviceID,
                      afterAccountOpenForTesting: nil)
    }

    init(directory: URL, accountPartition: String, deviceID: UUID,
         afterAccountOpenForTesting: (@Sendable () throws -> Void)?, authorityDirectory: URL? = nil) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0), isDigest(accountPartition)
        else { throw ChapterWorkerError.invalidIdentity }
        // The caller supplies an existing app-owned base. All descendants are
        // resolved relative to retained FDs, never re-resolved through ancestors.
        let base = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard base >= 0 else { throw ChapterOutboxError.storage }
        defer { Darwin.close(base) }
        let account = try Self.childDirectory(parent: base, name: accountPartition)
        defer { Darwin.close(account) }
        try afterAccountOpenForTesting?()
        let dir = try Self.childDirectory(parent: account, name: deviceID.uuidString.lowercased())
        let lock = openat(dir, "owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard lock >= 0 else { Darwin.close(dir); throw ChapterOutboxError.storage }
        let owner = Ownership(directory: dir, lock: lock)
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ChapterOutboxError.alreadyOpen }
        let storedBinding = try ChapterAuthorityBindingFile.read(dir)
        let writer: ChapterIntentHeadWriter?
        let loaded: Loaded
        if let authorityDirectory {
            if let storedBinding {
                let candidate = try ChapterIntentHeadWriter(directory: authorityDirectory, partition: accountPartition, device: deviceID, expected: storedBinding)
                try candidate.block() // Both locks and immutable owner binding verified before touching channel.
                loaded = try Self.load(directory: dir, partition: accountPartition, deviceID: deviceID, expectedAuthority: storedBinding, requireJournal: true)
                writer = candidate
            } else {
                loaded = try Self.load(directory: dir, partition: accountPartition, deviceID: deviceID)
                let candidate = try ChapterIntentHeadWriter(directory: authorityDirectory, partition: accountPartition, device: deviceID, expected: nil)
                try ChapterAuthorityBindingFile.publish(candidate.descriptor, directory: dir)
                try candidate.block()
                writer = candidate
            }
        } else {
            guard storedBinding == nil else { throw ChapterDurableAuthorityError.configurationRequired }
            loaded = try Self.load(directory: dir, partition: accountPartition, deviceID: deviceID)
            writer = nil
        }
        self.accountPartition = accountPartition; self.deviceID = deviceID
        entries = loaded.entries; authorityBinding = writer?.descriptor; headWriter = writer
        authorityReady = writer == nil
        ownership = owner
    }

    /// Explicit Reader-only mode. Keeps V5 and its pinned authority binding even
    /// for an empty journal; plain/older writers cannot bypass its barrier.
    public static func openWithDurableAuthority(directory: URL, authorityDirectory: URL,
                                                accountPartition: String, deviceID: UUID) async throws -> ChapterDemandOutbox {
        try await openWithDurableAuthority(directory: directory, authorityDirectory: authorityDirectory,
            accountPartition: accountPartition, deviceID: deviceID, afterRecoveryForTesting: { _ in })
    }
    static func openWithDurableAuthority(directory: URL, authorityDirectory: URL,
                                         accountPartition: String, deviceID: UUID,
                                         afterRecoveryForTesting: @escaping @Sendable (ChapterDemandOutbox) async throws -> Void) async throws -> ChapterDemandOutbox {
        try Task.checkCancellation()
        let value = try ChapterDemandOutbox(directory: directory, accountPartition: accountPartition, deviceID: deviceID,
            afterAccountOpenForTesting: nil, authorityDirectory: authorityDirectory)
        do {
            try await value.recoverAuthority()
            try await afterRecoveryForTesting(value)
            try Task.checkCancellation()
            return value
        } catch { await value.blockAndCloseAfterFailure(); throw error }
    }
    private func blockAndCloseAfterFailure() {
        uncertain = true
        try? headWriter?.block(ignoreCancellation: true)
        close()
    }
    private func recoverAuthority() throws {
        guard let headWriter, authorityBinding != nil else { throw ChapterDurableAuthorityError.configurationRequired }
        do {
            try persist(entries) // V5 is durable BEFORE a ready head, including empty initialization.
            try headWriter.publish(Self.readSets(entries))
            try Task.checkCancellation()
            authorityReady = true
        } catch {
            uncertain = true
            try? headWriter.block(ignoreCancellation: true)
            throw error
        }
    }
    public func durableIntentDescriptor() throws -> ChapterDurableIntentDescriptor {
        try writable()
        guard let authorityBinding else { throw ChapterDurableAuthorityError.configurationRequired }
        return authorityBinding
    }
    private static func readSets(_ values: [String: Entry]) throws -> [ChapterIntentReadSet] {
        try values.sorted(by: { $0.key < $1.key }).compactMap { _, entry in
            guard entry.intent.wanted, let source = entry.sourceReference, let plan = entry.renderPlanReference else { return nil }
            return try .init(intent: entry.intent, sourceReference: source, renderPlanReference: plan)
        }
    }

    /// Same wanted value is idempotent, including after acknowledgement. Keep
    /// acknowledged tombstones so future cancel/re-request revisions never reset.
    @discardableResult
    public func setDemand(_ wanted: Bool, for request: ChapterRenderRequest) throws -> ChapterDemandIntent {
        try setDemandOwned(wanted, request: request, sourceReference: nil)
    }
    /// Call only after immutable exact source publication. The pending intent
    /// and reference commit in one Reader-owned journal snapshot. A crash may
    /// leave an orphan source publication; source existence alone is never work.
    @discardableResult
    public func setDemand(_ wanted: Bool, for request: ChapterRenderRequest,
                          source: ChapterLocalSourcePublication) throws -> ChapterDemandIntent {
        try writable(); try Task.checkCancellation()
        guard source.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard try ChapterTextAssetManifest.sourceKey(for: source.source) == ChapterTextAssetManifest.sourceKey(for: request.source)
        else { throw ChapterWorkerError.invalidIdentity }
        return try setDemandOwned(wanted, request: request, sourceReference: source.reference)
    }
    /// Atomically attaches exact source and portable options to this Reader intent.
    /// A publication is not a worker claim; current intent must be checked again.
    @discardableResult
    public func setDemand(_ wanted: Bool, for request: ChapterRenderRequest,
                          source: ChapterLocalSourcePublication,
                          renderPlan: ChapterLocalRenderPlanPublication) throws -> ChapterDemandIntent {
        try writable(); try Task.checkCancellation()
        guard source.accountPartition == accountPartition, renderPlan.accountPartition == accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        guard try ChapterTextAssetManifest.sourceKey(for: source.source) == ChapterTextAssetManifest.sourceKey(for: request.source),
              renderPlan.sourceReference == source.reference, renderPlan.renderKey == (try request.renderKey())
        else { throw ChapterWorkerError.invalidIdentity }
        return try setDemandOwned(wanted, request: request, sourceReference: source.reference, renderPlanReference: renderPlan.reference)
    }
    /// Snapshot before asynchronous source/plan production, including absence.
    public func observeAdmission(for request: ChapterRenderRequest) throws -> ChapterDemandAdmission {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        let key = try request.renderKey()
        return .init(owner: admissionOwner, commandStamp: admissionCommandStamp, request: request,
            renderKey: key, priorIntent: entries[key]?.intent)
    }
    /// The current-intent comparison and triple attachment share this actor turn.
    /// Even an idempotent cancel/re-request invalidates an earlier admission.
    @discardableResult
    public func setDemand(_ wanted: Bool, for request: ChapterRenderRequest,
                          source: ChapterLocalSourcePublication, renderPlan: ChapterLocalRenderPlanPublication,
                          admission: ChapterDemandAdmission) throws -> ChapterDemandIntent {
        try writable(); try Task.checkCancellation()
        guard admission.owner == admissionOwner, admission.commandStamp == admissionCommandStamp,
              admission.request.accountPartition == request.accountPartition,
              admission.renderKey == (try request.renderKey()), try entries[request.renderKey()]?.intent == admission.priorIntent
        else { throw ChapterLocalIntentError.staleIntent }
        return try setDemand(wanted, for: request, source: source, renderPlan: renderPlan)
    }
    private func setDemandOwned(_ wanted: Bool, request: ChapterRenderRequest,
                                sourceReference: ChapterLocalSourceReference?,
                                renderPlanReference: ChapterLocalRenderPlanReference? = nil) throws -> ChapterDemandIntent {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard request.recipe.watermarkRevision == "disabled-1" else { throw ChapterOutboxError.unsupportedPolicy }
        // A fixed-size live command fence, deliberately conservative across
        // chapters. Do not let an idempotent cancel disappear during publication.
        admissionCommandStamp = UUID()
        let key = try request.renderKey()
        let nextSource = sourceReference ?? entries[key]?.sourceReference
        let nextPlan = renderPlanReference ?? entries[key]?.renderPlanReference
        if let old = entries[key], old.intent.wanted == wanted, old.sourceReference == nextSource, old.renderPlanReference == nextPlan { return old.intent }
        guard entries[key] != nil || entries.count < Self.maximumEntries,
              (entries[key]?.intent.revision ?? 0) < .max else { throw ChapterOutboxError.budgetExceeded }
        let intent = ChapterDemandIntent(request: request, deviceID: deviceID,
            revision: (entries[key]?.intent.revision ?? 0) + 1, wanted: wanted)
        // Completed encoded assets survive cancellation/re-request. This is
        // independent of the new intent's pending/server confirmation state.
        var next = entries; next[key] = Entry(intent: intent, pending: true, handoff: entries[key]?.handoff, sourceReference: nextSource, renderPlanReference: nextPlan)
        try persist(next, intentMutation: true); entries = next; return intent
    }

    public func pending() throws -> [ChapterDemandIntent] {
        try writable()
        return entries.sorted(by: { $0.key < $1.key }).compactMap { $0.value.pending ? $0.value.intent : nil }
    }

    /// Lost/late acknowledgements cannot remove a newer local cancellation or
    /// re-request. No remote delivery is inferred from this local operation.
    @discardableResult
    public func acknowledge(_ intent: ChapterDemandIntent) throws -> Bool {
        try writable(); try Task.checkCancellation()
        guard intent.deviceID == deviceID, intent.request.accountPartition == accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        let key = try intent.request.renderKey()
        guard var old = entries[key], old.intent == intent else { return false }
        guard old.pending else { return true }
        old.pending = false; var next = entries; next[key] = old
        try persist(next); entries = next; return true
    }

    /// Persist the server version and cleared pending bit in ONE journal save.
    /// Later batch failure/cancellation cannot lose an already accepted receipt.
    @discardableResult
    public func confirm(_ intent: ChapterDemandIntent, serverRevision: ChapterServerRevision) throws -> Bool {
        try writable(); try Task.checkCancellation()
        guard intent.deviceID == deviceID, intent.request.accountPartition == accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        let key = try intent.request.renderKey()
        guard var old = entries[key], old.intent == intent else { return false }
        if !old.pending, old.serverRevision == serverRevision.opaqueValue { return true }
        old.pending = false; old.serverRevision = serverRevision.opaqueValue
        var next = entries; next[key] = old
        try persist(next); entries = next; return true
    }

    /// Latest exact intent confirmation, replayable across batch errors and
    /// process/account-epoch reopen. Caller rebinds it to a freshly validated
    /// matching session; this version is not a new observation of server state.
    public func confirmation(for request: ChapterRenderRequest) throws -> ChapterConfirmedDemand? {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard let entry = entries[try request.renderKey()], !entry.pending, let version = entry.serverRevision else { return nil }
        return .init(intent: entry.intent, serverRevision: try .init(opaqueValue: version))
    }

    /// Remember only for the exact current wanted intent. A late producer
    /// callback cannot overwrite a newer cancellation/re-request. This never
    /// clears pending demand, supplies serverRevision or asserts availability.
    @discardableResult
    public func rememberHandoff(_ reference: ChapterLocalHandoffReference, for intent: ChapterDemandIntent) throws -> Bool {
        try writable(); try Task.checkCancellation()
        guard intent.deviceID == deviceID, intent.request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        let key = try intent.request.renderKey()
        guard var old = entries[key], old.intent == intent, intent.wanted else { return false }
        let stored = StoredHandoff(reference: reference, recordedAtIntentRevision: intent.revision)
        if old.handoff == stored { return true }
        old.handoff = stored
        var next = entries; next[key] = old
        try persist(next); entries = next
        return true
    }

    /// Reader-only acceptance AFTER actual complete audio receive/adoption. The
    /// exact wanted revision and retained handoff update share this journal actor;
    /// an observation from the Worker is never a substitute for this comparison.
    public func acceptVerifiedHandoff(_ artifact: ChapterLocalArtifact, submission: ChapterSubmission,
                                      readSet: ChapterIntentReadSet, gate: ChapterAccountSessionGate) async throws -> ChapterReaderArtifactAcceptance {
        try await acceptVerifiedHandoff(artifact, submission: submission, readSet: readSet, gate: gate, afterCommitForTesting: {})
    }
    func acceptVerifiedHandoff(_ artifact: ChapterLocalArtifact, submission: ChapterSubmission,
                               readSet: ChapterIntentReadSet, gate: ChapterAccountSessionGate,
                               afterCommitForTesting: @escaping @Sendable () async throws -> Void) async throws -> ChapterReaderArtifactAcceptance {
        try writable(); try Task.checkCancellation()
        try await gate.validate(submission.session); try Task.checkCancellation()
        guard submission.session.accountPartition == accountPartition,
              try submission.request.renderKey() == readSet.intent.request.renderKey(),
              try ChapterLocalSource.contentReference(for: submission) == readSet.sourceReference else { throw ChapterWorkerError.accountMismatch }
        let reference = try ChapterLocalHandoff.contentReference(for: artifact, submission: submission)
        guard try validateCurrent(readSet) else { throw ChapterLocalIntentError.staleIntent }
        // No await between current-intent comparison and the atomic journal save.
        guard try rememberHandoff(reference, for: readSet.intent) else { throw ChapterLocalIntentError.staleIntent }
        try await afterCommitForTesting()
        try await gate.validate(submission.session); try Task.checkCancellation()
        guard try validateCurrent(readSet) else { throw ChapterLocalIntentError.staleIntent }
        return .init(artifact: artifact, readSet: readSet, reference: reference)
    }

    /// Retained independently of current wanted/pending state; completed audio
    /// is not deleted on cancel. The original intent revision remains explicit.
    /// A missing/corrupt publication still fails verified receiver adoption.
    public func retainedHandoff(for request: ChapterRenderRequest) throws -> ChapterRetainedHandoff? {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard let entry = entries[try request.renderKey()], let handoff = entry.handoff else { return nil }
        guard entry.intent.request == request else { throw ChapterOutboxError.corrupt }
        return .init(request: request, reference: handoff.reference, recordedAtIntentRevision: handoff.recordedAtIntentRevision)
    }
    public func storedSubmission(for request: ChapterRenderRequest) throws -> ChapterStoredSubmission? {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard let entry = entries[try request.renderKey()], let source = entry.sourceReference else { return nil }
        guard entry.intent.request == request else { throw ChapterOutboxError.corrupt }
        return .init(intent: entry.intent, sourceReference: source, renderPlanReference: entry.renderPlanReference)
    }

    /// Reader-owned atomic read of the exact wanted intent plus both durable
    /// references. Legacy/incomplete/cancelled entries are not render work.
    public func wantedReadSet(for request: ChapterRenderRequest) throws -> ChapterIntentReadSet? {
        try writable(); try Task.checkCancellation(); try request.validate()
        guard request.accountPartition == accountPartition else { throw ChapterWorkerError.accountMismatch }
        guard let entry = entries[try request.renderKey()], entry.intent.wanted,
              let source = entry.sourceReference, let plan = entry.renderPlanReference else { return nil }
        return try .init(intent: entry.intent, sourceReference: source, renderPlanReference: plan)
    }
    /// Call in the Reader owner; remote Worker access uses only authenticated
    /// read-only authority messages, never opening this mutable journal itself.
    public func validateCurrent(_ readSet: ChapterIntentReadSet) throws -> Bool {
        try writable(); try Task.checkCancellation()
        guard readSet.intent.deviceID == deviceID, readSet.intent.request.accountPartition == accountPartition
        else { throw ChapterWorkerError.accountMismatch }
        return try wantedReadSet(for: readSet.intent.request) == readSet
    }

    public func close() { headWriter = nil; ownership = nil }
    func failAuthorityForTesting(_ callback: (@Sendable (AuthorityEvent) throws -> Void)?) { authorityFaultForTesting = callback }
    func failAfterNextRenameForTesting() { afterRenameForTesting = { throw ChapterOutboxError.storage } }
    func cancelAfterNextRenameForTesting() { afterRenameForTesting = { withUnsafeCurrentTask { $0?.cancel() } } }

    private func writable() throws {
        guard ownership != nil else { throw ChapterOutboxError.closed }
        guard !uncertain else { throw ChapterOutboxError.ambiguousWrite }
        guard authorityReady else { throw ChapterDurableAuthorityError.configurationRequired }
    }
    private static func childDirectory(parent: Int32, name: String) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST { throw ChapterOutboxError.storage }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChapterOutboxError.storage }
        guard fsync(parent) == 0 else { Darwin.close(fd); throw ChapterOutboxError.storage }
        return fd
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func load(directory: Int32, partition: String, deviceID: UUID,
                             expectedAuthority: ChapterDurableIntentDescriptor? = nil, requireJournal: Bool = false) throws -> Loaded {
        let descriptor = openat(directory, "journal.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw ChapterOutboxError.corrupt }
            guard !requireJournal else { throw ChapterOutboxError.corrupt }
            return .init(entries: [:], authority: nil)
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= maximumJournalBytes else { throw ChapterOutboxError.corrupt }
        let bytes = try file.read(upToCount: maximumJournalBytes + 1) ?? Data()
        guard bytes.count == info.st_size else { throw ChapterOutboxError.corrupt }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: bytes) }
        catch { throw ChapterOutboxError.corrupt }
        // Once the immutable mode binding exists, recovery never treats an
        // older/downgraded journal as a fresh activation. Preserve uncertainty.
        guard !requireJournal || journal.authority == expectedAuthority else { throw ChapterOutboxError.corrupt }
        if journal.authority != nil, expectedAuthority == nil { throw ChapterDurableAuthorityError.configurationRequired }
        guard journal.authority == nil || journal.authority == expectedAuthority else { throw ChapterOutboxError.corrupt }
        let expectedVersion = journal.authority == nil ? Self.version(journal.entries) : 5
        guard journal.version == expectedVersion, journal.partition == partition, journal.deviceID == deviceID,
              journal.entries.count <= maximumEntries, try checksum(journal.entries, authority: journal.authority) == journal.checksum
        else { throw ChapterOutboxError.corrupt }
        for (key, entry) in journal.entries {
            guard entry.intent.revision > 0, entry.intent.deviceID == deviceID,
                  entry.intent.request.accountPartition == partition,
                  entry.intent.request.recipe.watermarkRevision == "disabled-1",
                  try entry.intent.request.renderKey() == key else { throw ChapterOutboxError.corrupt }
            if let version = entry.serverRevision {
                guard !entry.pending else { throw ChapterOutboxError.corrupt }
                do { _ = try ChapterServerRevision(opaqueValue: version) }
                catch { throw ChapterOutboxError.corrupt }
            }
            if entry.renderPlanReference != nil, entry.sourceReference == nil { throw ChapterOutboxError.corrupt }
            if let handoff = entry.handoff {
                guard handoff.recordedAtIntentRevision > 0, handoff.recordedAtIntentRevision <= entry.intent.revision
                else { throw ChapterOutboxError.corrupt }
            }
        }
        return .init(entries: journal.entries, authority: journal.authority)
    }

    private static func checksum(_ entries: [String: Entry], authority: ChapterDurableIntentDescriptor?) throws -> String {
        if let authority { return digest(try encoded(AuthorityChecksum(entries: entries, authority: authority))) }
        return digest(try encoded(entries))
    }
    private func persist(_ next: [String: Entry], intentMutation: Bool = false) throws {
        guard let ownership else { throw ChapterOutboxError.closed }
        let data = try Self.encoded(Journal(version: authorityBinding == nil ? Self.version(next) : 5, partition: accountPartition, deviceID: deviceID,
                                           entries: next, checksum: Self.checksum(next, authority: authorityBinding), authority: authorityBinding))
        guard data.count <= Self.maximumJournalBytes else { throw ChapterOutboxError.budgetExceeded }
        if intentMutation, let headWriter {
            do {
                try headWriter.block()
                try authorityFaultForTesting?(.afterBlocked)
                try saveJournal(data, ownership: ownership)
                try authorityFaultForTesting?(.afterJournal)
                try headWriter.publish(Self.readSets(next)) { try authorityFaultForTesting?(.afterArchive) }
                try authorityFaultForTesting?(.afterReady)
                try Task.checkCancellation()
                return
            } catch {
                uncertain = true
                // Failure cleanup ignores task cancellation. If the OS refuses
                // this write, retain ambiguous evidence; never restore old ready.
                try? headWriter.block(ignoreCancellation: true)
                throw ChapterOutboxError.ambiguousWrite
            }
        }
        try saveJournal(data, ownership: ownership)
    }
    private func saveJournal(_ data: Data, ownership: Ownership) throws {
        let name = ".pending-" + UUID().uuidString
        let fd = openat(ownership.directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw ChapterOutboxError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(ownership.directory, name, 0) }
        try file.write(contentsOf: data)
        guard fsync(fd) == 0 else { throw ChapterOutboxError.storage }
        try Task.checkCancellation()
        guard renameat(ownership.directory, name, ownership.directory, "journal.json") == 0
        else { throw ChapterOutboxError.storage }
        do {
            let hook = afterRenameForTesting; afterRenameForTesting = nil; try hook?()
            guard fsync(ownership.directory) == 0 else { throw ChapterOutboxError.storage }
        } catch {
            // Rename may have committed. Never accept another write based on
            // stale memory: close/reopen and reconcile the journal first.
            uncertain = true; throw ChapterOutboxError.ambiguousWrite
        }
    }
    private static func version(_ entries: [String: Entry]) -> Int {
        // Existing encodings/checksums remain unchanged until a new field is
        // actually stored. Older writers must fail closed instead of stripping it.
        if entries.values.contains(where: { $0.renderPlanReference != nil }) { return 4 }
        if entries.values.contains(where: { $0.sourceReference != nil }) { return 3 }
        return entries.values.contains(where: { $0.handoff != nil }) ? 2 : 1
    }
}
