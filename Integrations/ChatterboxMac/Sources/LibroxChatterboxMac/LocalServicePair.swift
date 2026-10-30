#if os(macOS)
import Foundation
import Darwin
import LibroxChapterWorker
import LibroxChatterboxPlanning

private actor LocalCatalogConnection {
    private var worker: ChatterboxMacLocalWorkerHost?
    func attach(_ worker: ChatterboxMacLocalWorkerHost) { self.worker = worker }
    func catalog(_ session: ChapterAccountSession, gate: ChapterAccountSessionGate) async throws -> ChatterboxStockCatalog {
        guard let worker else { throw ChatterboxLocalPreparedServiceError.notReady }
        return try await worker.catalog(for: session, gate: gate)
    }
}

/// Complete same-process local construction, with distinct Reader/Worker owners.
/// This is the first local host route, NOT cross-process IPC or an iCloud route.
/// The application supplies authorized text/settings/assets and lifecycle; the
/// SDK owns journals, budgets, model preparation, claims, exports and adoption.
public struct ChatterboxMacLocalServicePair: Sendable {
    public let reader: ChatterboxLocalPreparedChapterService
    public let worker: ChatterboxMacLocalWorkerHost
    private let readerSession: ChapterAccountSession

    public static func open(assets: ChatterboxMacModelAssets,
                            readerSession: ChapterAccountSession, readerGate: ChapterAccountSessionGate, deviceID: UUID,
                            workerSession: ChapterAccountSession, workerGate: ChapterAccountSessionGate, workerID: UUID,
                            readerDirectories: ChatterboxLocalReaderDirectories, workerDirectories: ChatterboxMacWorkerDirectories,
                            publicationPolicy: ChapterStorageBudgetPolicy, artifactPolicy: ChapterStorageBudgetPolicy,
                            workerPolicy: ChapterStorageBudgetPolicy,
                            listeningApproval: ChapterStockCapability.ListeningApproval = .pending) async throws -> ChatterboxMacLocalServicePair {
        let validation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard readerSession.accountPartition == workerSession.accountPartition else { throw ChapterWorkerError.accountMismatch }
            try readerDirectories.validate(); try workerDirectories.validate()
            func same(_ a: URL, _ b: URL) -> Bool { a.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL }
            guard same(readerDirectories.sources, workerDirectories.sourcePublications),
                  same(readerDirectories.plans, workerDirectories.planPublications),
                  same(readerDirectories.publications, workerDirectories.publications) else { throw ChatterboxMacWorkerError.invalidDirectories }
            let urls = [readerDirectories.sources, readerDirectories.plans, readerDirectories.outbox, readerDirectories.authority,
                readerDirectories.artifacts, readerDirectories.publications, workerDirectories.sourcePublications,
                workerDirectories.planPublications, workerDirectories.state, workerDirectories.exports,
                workerDirectories.custody, workerDirectories.publications]
            var identities: [(path: String, device: Int32, inode: UInt64)] = []
            for url in urls {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                var value = stat()
                guard lstat(resolved.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw ChatterboxMacWorkerError.invalidDirectories }
                identities.append((resolved.path, value.st_dev, value.st_ino))
            }
            for a in identities.indices {
                for b in identities.indices where b > a {
                    let x = identities[a], y = identities[b]
                    let sameRoot = x.device == y.device && x.inode == y.inode && x.path == y.path
                    if sameRoot, (a == 0 && b == 6 || a == 1 && b == 7 || a == 5 && b == 11) { continue }
                    guard !(x.device == y.device && x.inode == y.inode), x.path != y.path,
                          !x.path.hasPrefix(y.path + "/"), !y.path.hasPrefix(x.path + "/")
                    else { throw ChatterboxMacWorkerError.invalidDirectories }
                }
            }
            try readerDirectories.validate(); try workerDirectories.validate(); try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
        let endpoint = LocalCatalogConnection()
        let reader = try await ChatterboxLocalPreparedChapterService.open(session: readerSession, gate: readerGate, deviceID: deviceID,
            directories: readerDirectories, publicationPolicy: publicationPolicy, artifactPolicy: artifactPolicy) { session in
                try await endpoint.catalog(session, gate: readerGate)
            }
        var worker: ChatterboxMacLocalWorkerHost?
        do {
            let descriptor = try await reader.localIntentDescriptor(session: readerSession)
            let authority = ChapterDurableIntentAuthority(directory: readerDirectories.authority, descriptor: descriptor)
            let host = try await ChatterboxMacLocalWorkerHost.open(assets: assets, workerID: workerID, session: workerSession,
                gate: workerGate, directories: workerDirectories, authority: authority, storagePolicy: workerPolicy, listeningApproval: listeningApproval)
            worker = host
            await endpoint.attach(host)
            try await readerGate.validate(readerSession); try await workerGate.validate(workerSession); try Task.checkCancellation()
            return .init(reader: reader, worker: host, readerSession: readerSession)
        } catch {
            try? await worker?.shutdown(); try? await reader.close(session: readerSession); throw error
        }
    }
    /// Same caller-turn cancellation fence, followed by the terminal join below.
    public func stopClaims() { worker.stopClaims() }
    public func shutdown() async throws {
        stopClaims()
        var first: Error?
        do { try await worker.shutdown() } catch { first = error }
        do { try await reader.close(session: readerSession) } catch { if first == nil { first = error } }
        if let first { throw first }
    }
}
#endif
