import Foundation
import CloudKit
import LibroxChapterWorker

/// Concrete private-iCloud reader. Owns only the reader role; never loads MLX.
/// The app owns account changes and calls stopRequests(), then awaits close().
public actor ChatterboxCloudPreparedBookService: ChatterboxPreparedBookService {
    private let connection: ChatterboxCloudBookConnection
    private let outbox: ChapterBookOutbox
    private let control: ChapterCloudBookControlTransport
    private nonisolated let operations = ChatterboxCloudOperations()
    private var admissions: [String: Task<Void, Never>] = [:]
    private var sourceProviders: [String: any ChatterboxBookSourceProvider] = [:]
    private var failures: [String: Error] = [:]
    private var titles: [String: String] = [:]
    private var observers: [UUID: Task<Void, Never>] = [:]
    private var closeTask: Task<Void, Error>?
    private var synchronizing = false

    private init(connection: ChatterboxCloudBookConnection, outbox: ChapterBookOutbox,
                 control: ChapterCloudBookControlTransport) {
        self.connection = connection; self.outbox = outbox; self.control = control
    }
    public static func open(container: CKContainer, account: ChapterCloudAccountIdentity,
                            session: ChapterAccountSession, gate: ChapterAccountSessionGate,
                            deviceID: UUID, readerDirectory: URL, storagePolicy: ChapterStorageBudgetPolicy,
                            authorizeTransfer: @escaping @Sendable () async throws -> Void) async throws -> Self {
        let task = Task.detached(priority: .utility) {
            try await gate.validate(session); try Task.checkCancellation()
            let connection = try ChatterboxCloudBookConnection(container: container, account: account,
                session: session, gate: gate, root: readerDirectory, policy: storagePolicy, authorize: authorizeTransfer)
            do {
                let journal = readerDirectory.appendingPathComponent("Outbox", isDirectory: true)
                try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let outbox = try ChapterBookOutbox(directory: journal, accountPartition: session.accountPartition, deviceID: deviceID)
                let control = try ChapterCloudBookControlTransport(container: container, account: account, session: session,
                    gate: gate, authorizeControlTransfer: authorizeTransfer,
                    requireCurrent: { try await outbox.requireCurrentIntent($0) })
                return Self(connection: connection, outbox: outbox, control: control)
            } catch { try? await connection.budget.close(); throw error }
        }
        let service = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do { try Task.checkCancellation(); try await gate.validate(session); return service }
        catch { try? await service.close(session: session); throw error }
    }
    private func valid(_ session: ChapterAccountSession) async throws {
        try operations.check()
        guard session == connection.session else { throw ChapterWorkerError.accountMismatch }
        try await connection.gate.validate(session); try operations.check()
    }
    /// Explicit user-enabled setup. Existing private data is never cleared.
    public func connect(session: ChapterAccountSession) async throws {
        try await valid(session)
        try await operations.run { [connection] in try await connection.directory.prepareZone() }
        try await valid(session)
    }
    public func catalog(session: ChapterAccountSession) async throws -> ChatterboxStockCatalog {
        try await valid(session)
        return try await operations.run { [connection] in
            guard let bytes = try await connection.directory.catalog() else { throw ChatterboxCloudServiceError.notReady }
            let record = try JSONDecoder().decode(ChatterboxCloudStockRecord.self, from: bytes)
            let descriptor = try record.descriptor()
            // Catalog means this exact backend has prepared on a Mac. It is not
            // a heartbeat or a guarantee that the Mac is currently awake.
            return try .init(session: session, voices: [.init(descriptor: descriptor,
                availability: .available, listeningApproval: .pending, deliveryFormats: [.smaller, .lossless])])
        }
    }
    public func books(session: ChapterAccountSession) async throws -> [ChatterboxCloudBookSummary] {
        try await valid(session)
        return try await operations.run { [connection] in
            var result: [ChatterboxCloudBookSummary] = []
            for book in try await connection.directory.books() {
                let wanted = try await connection.directory.readSets(scopeID: book.scopeID)
                result.append(.init(scopeID: book.scopeID, title: book.title, requested: !wanted.isEmpty))
            }
            return result
        }
    }
    public func setTitle(_ title: String, scopeID: String, session: ChapterAccountSession) async throws {
        try await valid(session)
        _ = try ChapterCloudBookListing(scopeID: scopeID, title: title)
        titles[scopeID] = title
    }
    public func begin(_ book: ChatterboxPreparedBookSubmission, source: any ChatterboxBookSourceProvider,
                      priority: ChapterBookPriority, session: ChapterAccountSession) async throws -> ChatterboxBookDemandReceipt {
        try await valid(session)
        guard source.book == book.scope.book, book.scope.accountPartition == session.accountPartition,
              book.supportsCurrentPlanner else { throw ChapterWorkerError.invalidIdentity }
        let catalog = try await catalog(session: session)
        guard let descriptor = catalog.voices.first?.descriptor,
              try descriptor.prepareBook(source: source.book, settings: book.settings, session: session).scope == book.scope else {
            throw ChapterServiceError.unsupportedPolicy
        }
        try await operations.run { [outbox] in
            _ = try await outbox.setWanted(true, scope: book.scope, priority: priority)
        }
        try await resumeSourceAdmission(scopeID: book.scope.identifier, source: source, session: session)
        return try await receipt(book.scope.identifier)
    }
    public func resumeSourceAdmission(scopeID: String, source: any ChatterboxBookSourceProvider,
                                      session: ChapterAccountSession) async throws {
        try await valid(session)
        guard admissions[scopeID] == nil else { return }
        guard let stored = try await outbox.stored(scopeID: scopeID), stored.intent.wanted,
              source.book == stored.scope.book else { throw ChatterboxCloudServiceError.staleIntent }
        let book = try ChatterboxPreparedBookSubmission.restore(scope: stored.scope, session: session)
        failures[scopeID] = nil
        sourceProviders[scopeID] = source
        admissions[scopeID] = Task { [weak self, operations] in
            guard let self else { return }
            do { try await operations.run { try await self.admit(book, source: source) } }
            catch { await self.admissionFailed(error, scopeID: scopeID) }
            await self.admissionFinished(scopeID)
        }
    }
    private func admissionFailed(_ error: Error, scopeID: String) { failures[scopeID] = error }
    private func admissionFinished(_ scopeID: String) { admissions[scopeID] = nil; sourceProviders[scopeID] = nil }
    private func admit(_ book: ChatterboxPreparedBookSubmission, source: any ChatterboxBookSourceProvider) async throws {
        let c = connection, session = c.session, scope = book.scope.identifier
        for index in source.book.chapterKeys.indices {
            try await valid(session)
            guard let current = try await outbox.stored(scopeID: scope), current.intent.wanted else {
                throw ChatterboxCloudServiceError.staleIntent
            }
            let text = try await source.chapter(at: index)
            try await valid(session)
            let entry = try book.prepareEntry(chapterIndex: index, text: text.text,
                performanceDirections: text.performanceDirections, session: session)
            switch entry {
            case .chapter(let prepared):
                _ = try await ChatterboxBookSubmissionAdmission.submit(prepared, book: book, chapterIndex: index,
                    gate: c.gate, outbox: outbox, budget: c.budget, sourceDirectory: c.sources, planDirectory: c.plans)
            case .silent(let proof):
                _ = try await ChatterboxBookSubmissionAdmission.submitSilent(proof, originalText: text.text,
                    book: book, session: session, gate: c.gate, outbox: outbox)
            }
            let content = try ChatterboxBookEntryContent(book: book, chapterIndex: index,
                originalText: text.text, entry: entry, session: session)
            _ = try await ChatterboxLocalBookContent.persist(content, book: book, session: session, gate: c.gate,
                outbox: outbox, budget: c.budget, directory: c.contents, sourceDirectory: c.sources, planDirectory: c.plans)
        }
        try await synchronize(scope)
    }
    /// Replays already-durable content and intent after an offline launch. The
    /// caller separately resumes lazy source extraction when it is incomplete.
    public func retryPending(session: ChapterAccountSession) async throws {
        try await valid(session)
        try await operations.run { [weak self, outbox] in
            guard let self else { throw ChatterboxCloudServiceError.closed }
            for pending in try await outbox.pending(maximum: 64) {
                try await self.synchronize(pending.scope.identifier)
            }
        }
    }
    private func synchronize(_ scope: String) async throws {
        // Native asset/control transports have one owned operation at a time.
        // A concurrent caller leaves its durable pending bit for the next pass.
        guard !synchronizing else { return }
        synchronizing = true; defer { synchronizing = false }
        let c = connection
        try await valid(c.session)
        guard let initial = try await outbox.stored(scopeID: scope) else { throw ChatterboxCloudServiceError.notFound }
        if !initial.intent.wanted {
            let result = try await control.cancel(initial.intent)
            guard try await outbox.confirm(result.intent, serverRevision: result.revision) else { throw ChatterboxCloudServiceError.staleIntent }
            return
        }
        let book = try ChatterboxPreparedBookSubmission.restore(scope: initial.scope, session: c.session)
        while try await ChatterboxBookContentUpload.reconcileOne(book: book, session: c.session, gate: c.gate,
            outbox: outbox, directory: c.contents, budget: c.budget, transport: c.entries) != nil { try await valid(c.session) }
        guard let stored = try await outbox.stored(scopeID: scope) else { throw ChatterboxCloudServiceError.notFound }
        let set = try ChapterBookReadSet(stored)
        let uploaded = try await c.readSets.upload(set)
        let result = try await control.publish(set, contentReceipt: uploaded)
        try await c.directory.list(.init(scopeID: scope, title: titles[scope] ?? "Book"))
        guard try await outbox.confirm(result.intent, serverRevision: result.revision) else { throw ChatterboxCloudServiceError.staleIntent }
        failures[scope] = nil
        try await valid(c.session)
    }
    public func preparedBook(scopeID: String, session: ChapterAccountSession) async throws -> ChatterboxPreparedBookSubmission? {
        try await valid(session)
        return try await operations.run { [outbox] in
            try await outbox.stored(scopeID: scopeID).map { try .restore(scope: $0.scope, session: session) }
        }
    }
    public func prioritize(_ position: ChapterBookPriority, scopeID: String, session: ChapterAccountSession) async throws -> ChatterboxBookDemandReceipt {
        try await valid(session)
        let source = sourceProviders[scopeID]
        admissions[scopeID]?.cancel()
        await admissions[scopeID]?.value
        try await valid(session)
        try await operations.run { [weak self, outbox] in
            _ = try await outbox.prioritize(position, scopeID: scopeID)
            // While extracting, the final source transaction publishes priority.
            if await self?.admissions[scopeID] == nil { try await self?.synchronize(scopeID) }
        }
        if let source { try await resumeSourceAdmission(scopeID: scopeID, source: source, session: session) }
        return try await receipt(scopeID)
    }
    private func receipt(_ scope: String) async throws -> ChatterboxBookDemandReceipt {
        try await valid(connection.session)
        guard let stored = try await outbox.stored(scopeID: scope) else { throw ChatterboxCloudServiceError.notFound }
        return try .init(stored: stored, session: connection.session)
    }
    private func current(_ scope: String) async throws -> ChatterboxPreparedBookReadSet? {
        let receipt = try await receipt(scope)
        guard receipt.localIntent.wanted else { throw ChatterboxCloudServiceError.staleIntent }
        let sets = try await connection.currentSets(scopeID: scope)
        return sets.first { $0.metadata.intent == receipt.localIntent }
    }
    public func resolve(scopeID: String, position: ChapterBookPriority, session: ChapterAccountSession) async throws -> ChatterboxBookResolution {
        try await valid(session)
        return try await operations.run { try await self.resolveOwned(scopeID, chapter: position.chapterIndex,
            offset: position.sourceUTF16Offset, afterSegment: nil) }
    }
    private func resolveOwned(_ scope: String, chapter: Int, offset: Int, afterSegment: Int?) async throws -> ChatterboxBookResolution {
        guard let set = try await current(scope) else { return .waiting(.waitingForSource) }
        guard set.book.scope.book.chapterKeys.indices.contains(chapter), offset >= 0 else { throw ChapterWorkerError.invalidIdentity }
        guard let content = try await connection.content(set, at: chapter) else { return .waiting(.waitingForSource) }
        if case .silent = content.entry { return try await nextChapter(scope, after: chapter) }
        guard case .chapter(let prepared) = content.entry else { throw ChapterWorkerError.invalidIdentity }
        guard offset <= content.originalText.utf16.count else { throw ChapterWorkerError.invalidIdentity }
        let admission = try ChapterBookWorkAdmission(readSet: set.metadata, request: prepared.submission.request, chapterIndex: chapter)
        let observation = try await connection.work.prefix(admission, through: nil, originalText: content.originalText)
        var prefix = try ChapterSegmentPrefix(request: prepared.submission.request, originalText: content.originalText)
        for manifest in observation.manifests {
            try prefix.append(manifest)
            let matches = afterSegment.map { manifest.segmentIndex > $0 }
                ?? (offset < manifest.sourceRange.offset + manifest.sourceRange.length)
            if matches {
                let unit = manifest.audio.units.last(where: { $0.source.offset <= offset }) ?? manifest.audio.units[0]
                return .segment(try .init(book: set.book, intent: set.metadata.intent, chapterIndex: chapter,
                    prepared: prepared, manifest: manifest, prefix: prefix, localStartFrame: afterSegment == nil ? unit.startFrame : 0))
            }
        }
        if let seal = observation.seal {
            return .chapterComplete(try .init(book: set.book, intent: set.metadata.intent, chapterIndex: chapter,
                prepared: prepared, seal: seal, finalPrefix: observation.prefix))
        }
        return .waiting(observation.manifests.isEmpty ? .queued : .rendering)
    }
    public func successor(of segment: ChatterboxResolvedBookSegment, session: ChapterAccountSession) async throws -> ChatterboxBookResolution {
        try await valid(session)
        return try await operations.run {
            guard try await self.receipt(segment.scopeID).localIntent.wantedRevision == segment.wantedRevision else {
                throw ChatterboxCloudServiceError.staleIntent
            }
            return try await self.resolveOwned(segment.scopeID, chapter: segment.chapterIndex, offset: 0,
                afterSegment: segment.manifest.segmentIndex)
        }
    }
    public func successor(of completion: ChatterboxResolvedBookChapterCompletion, session: ChapterAccountSession) async throws -> ChatterboxBookResolution {
        try await valid(session)
        return try await operations.run {
            guard try await self.receipt(completion.scopeID).localIntent.wantedRevision == completion.wantedRevision else {
                throw ChatterboxCloudServiceError.staleIntent
            }
            return try await self.nextChapter(completion.scopeID, after: completion.chapterIndex)
        }
    }
    private func nextChapter(_ scope: String, after index: Int) async throws -> ChatterboxBookResolution {
        guard let set = try await current(scope) else { return .waiting(.waitingForSource) }
        if index + 1 < set.book.scope.book.chapterKeys.count {
            return try await resolveOwned(scope, chapter: index + 1, offset: 0, afterSegment: nil)
        }
        // Verify every original spine entry and every actual chapter seal.
        for chapter in set.book.scope.book.chapterKeys.indices {
            guard let content = try await connection.content(set, at: chapter) else { return .waiting(.waitingForSource) }
            if case .chapter(let prepared) = content.entry {
                let admission = try ChapterBookWorkAdmission(readSet: set.metadata, request: prepared.submission.request, chapterIndex: chapter)
                let observation = try await connection.work.prefix(admission, through: nil, originalText: content.originalText)
                guard observation.seal != nil else { return .waiting(.rendering) }
            }
        }
        guard try await current(scope)?.metadata.intent == set.metadata.intent else { throw ChatterboxCloudServiceError.staleIntent }
        return .endOfBook
    }
    public func download(_ segment: ChatterboxResolvedBookSegment, session: ChapterAccountSession) async throws -> ChatterboxBookSegmentDelivery {
        try await valid(session)
        return try await operations.run { [connection] in
            guard let set = try await self.current(segment.scopeID), set.metadata.intent.wantedRevision == segment.wantedRevision else {
                throw ChatterboxCloudServiceError.staleIntent
            }
            try set.book.validate(segment.prepared, chapterIndex: segment.chapterIndex)
            let reservation = try await connection.budget.reserve(bytes: 64 * 1024 * 1024)
            do {
                let artifact = try await connection.segments.download(manifest: segment.manifest,
                    request: segment.prepared.submission.request, originalText: segment.prepared.submission.originalText)
                _ = try await connection.budget.settleAfterJoining(reservation)
                guard try await self.current(segment.scopeID)?.metadata.intent == set.metadata.intent else {
                    throw ChatterboxCloudServiceError.staleIntent
                }
                return try .init(resolution: segment, artifact: artifact)
            } catch { try? await connection.budget.releaseAfterJoining(reservation); throw error }
        }
    }
    public func cancelPreparation(scopeID: String, session: ChapterAccountSession) async throws -> ChatterboxBookDemandReceipt {
        try await valid(session)
        admissions[scopeID]?.cancel()
        await admissions[scopeID]?.value
        try await operations.run { [outbox] in
            guard let stored = try await outbox.stored(scopeID: scopeID) else { throw ChatterboxCloudServiceError.notFound }
            _ = try await outbox.setWanted(false, scope: stored.scope, priority: stored.intent.priority)
            try await self.synchronize(scopeID)
        }
        return try await receipt(scopeID)
    }
    public func updates(scopeID: String, session: ChapterAccountSession) async throws -> AsyncThrowingStream<ChatterboxBookServiceUpdate, Error> {
        try await valid(session)
        guard observers.count < 16 else { throw ChatterboxCloudServiceError.busy }
        let id = UUID(), pair = AsyncThrowingStream<ChatterboxBookServiceUpdate, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = Task { [weak self, operations] in
            guard let self else { pair.continuation.finish(); return }
            do {
                var sequence: UInt64 = 0
                while !Task.isCancelled {
                    sequence += 1
                    let number = sequence
                    let update = try await operations.run { try await self.snapshot(scopeID, sequence: number) }
                    pair.continuation.yield(update)
                    try await Task.sleep(for: .seconds(5))
                }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
            await self.removeObserver(id)
        }
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.cancelObserver(id) } }
        return pair.stream
    }
    private func cancelObserver(_ id: UUID) { observers[id]?.cancel() }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func snapshot(_ scope: String, sequence: UInt64) async throws -> ChatterboxBookServiceUpdate {
        let receipt = try await receipt(scope)
        guard let stored = try await outbox.stored(scopeID: scope) else { throw ChatterboxCloudServiceError.notFound }
        let total = stored.scope.book.chapterKeys.count
        let remoteFailure = try await connection.directory.failure(scopeID: scope)
        var complete = 0, admitted = stored.chapters.count
        var phase: ChatterboxBookPhase = failures[scope] == nil ? .waitingForSource : .failed
        if receipt.localIntent.wanted, let set = try await current(scope) {
            admitted = set.metadata.entries.count; phase = .queued
            for entry in set.metadata.entries {
                guard let content = try await connection.content(set, at: entry.chapterIndex) else { continue }
                if case .chapter(let prepared) = content.entry {
                    let admission = try ChapterBookWorkAdmission(readSet: set.metadata, request: prepared.submission.request, chapterIndex: entry.chapterIndex)
                    let prefix = try await connection.work.prefix(admission, through: nil, originalText: content.originalText)
                    if prefix.seal != nil { complete += 1 }
                    else if !prefix.manifests.isEmpty { phase = .rendering }
                } else { complete += 1 }
            }
            if complete == total { phase = .complete }
            else if remoteFailure != nil { phase = .failed }
        }
        return try .init(receipt: receipt, sequence: sequence, phase: phase,
            admittedSpineEntries: admitted, completeSpineEntries: complete, totalSpineEntries: total,
            lastFailure: complete == total ? nil : failures[scope]?.localizedDescription ?? remoteFailure)
    }
    public func status(scopeID: String, session: ChapterAccountSession) async throws -> ChatterboxBookServiceUpdate {
        try await valid(session)
        return try await operations.run { try await self.snapshot(scopeID, sequence: 1) }
    }
    public nonisolated func stopRequests() { operations.stop() }
    public func close(session: ChapterAccountSession) async throws {
        guard session == connection.session else { throw ChapterWorkerError.accountMismatch }
        if let closeTask { try await closeTask.value; return }
        operations.stop()
        let pending = Array(admissions.values) + Array(observers.values)
        pending.forEach { $0.cancel() }
        let task = Task { [operations, outbox, connection] in
            for task in pending { await task.value }
            await operations.join(); await outbox.close(); try await connection.budget.close()
        }
        closeTask = task; try await task.value
    }
}
