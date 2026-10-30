import Foundation
import Testing
import Darwin
@testable import LibroxChapterWorker

private actor BudgetPause {
    private var entered = false, released = false
    private var entry: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; entry?.resume(); entry = nil; if !released { await withCheckedContinuation { exit = $0 } } }
    func wait() async { if !entered { await withCheckedContinuation { entry = $0 } } }
    func open() { released = true; exit?.resume(); exit = nil }
}
private final class BudgetFixture: Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-budget-" + UUID().uuidString)
    let roots: [URL], outside: URL
    init() throws {
        let base = root
        roots = ["State", "Exports", "Custody", "Publications"].map { base.appendingPathComponent($0) }
        outside = root.appendingPathComponent("Unmanaged-Original-Models-And-Books")
        for url in [root] + roots + [outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func open(maximum: UInt64 = 1600, minimumFree: UInt64 = 0, entries: Int = 100_000, depth: Int = 32, reservations: Int = 8) throws -> ChapterArtifactStorageBudget {
        try .init(controlDirectory: roots[0], managedDirectories: roots,
            policy: .init(maximumManagedBytes: maximum, minimumAvailableBytes: minimumFree, maximumEntries: entries, maximumDepth: depth, maximumReservations: reservations))
    }
    func write(_ count: Int, root: Int = 1, name: String = "data") throws -> URL {
        let path = roots[root].appendingPathComponent(name); try Data(repeating: 7, count: count).write(to: path); return path
    }
}
@Suite(.serialized) struct ChapterArtifactStorageBudgetTests {
    @Test func boundedInventoryCountsUnknownAndOldPartitionsButNeverUnmanagedAssets() async throws {
        let f = try BudgetFixture()
        _ = try f.write(100, root: 0); _ = try f.write(200, root: 1); _ = try f.write(300, root: 2)
        let old = f.roots[3].appendingPathComponent("unknown-old-account"); try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let preserved = old.appendingPathComponent("keep"); try Data(repeating: 1, count: 400).write(to: preserved)
        let original = f.outside.appendingPathComponent("original"); try Data(repeating: 2, count: 10_000).write(to: original)
        let budget = try f.open()
        let result = try await budget.inventory()
        #expect(result.logicalBytes == 1000 && result.regularFiles >= 4 && result.directories >= 5)
        #expect(result.minimumVolumeAvailableBytes > 0)
        try await budget.close()
        #expect(try Data(contentsOf: preserved).count == 400 && Data(contentsOf: original).count == 10_000)
    }
    @Test func reservationsAreAtomicConservativeAndSettledOnlyAfterActualRemeasurement() async throws {
        let f = try BudgetFixture(), file = try f.write(1000), budget = try f.open()
        let first = try await budget.reserve(bytes: 400)
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await budget.reserve(bytes: 300) }
        let second = try await budget.reserve(bytes: 100)
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        try Data(repeating: 3, count: 1300).write(to: file)
        let measured = try await budget.settleAfterJoining(first)
        #expect(measured.logicalBytes == 1300)
        await #expect(throws: ChapterStorageBudgetError.staleReservation) { try await budget.releaseAfterJoining(first) }
        try await budget.releaseAfterJoining(second); try await budget.close()
    }
    @Test func overshootFailsSettlementAndPreservesCompletedUnknownFiles() async throws {
        let f = try BudgetFixture(), file = try f.write(1000), budget = try f.open()
        let token = try await budget.reserve(bytes: 500)
        try Data(repeating: 4, count: 1700).write(to: file)
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await budget.settleAfterJoining(token) }
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        #expect(try Data(contentsOf: file).count == 1700)
        try await budget.releaseAfterJoining(token); try await budget.close()
        let reopened = try f.open()
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await reopened.reserve(bytes: 1) }
        try await reopened.close()
    }
    @Test func settlementRetainsOtherActiveAllowancesEvenWhenCurrentFilesFit() async throws {
        let f = try BudgetFixture(), file = try f.write(1000), budget = try f.open()
        let first = try await budget.reserve(bytes: 400)
        let second = try await budget.reserve(bytes: 100)
        try Data(repeating: 5, count: 1550).write(to: file)
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await budget.settleAfterJoining(first) }
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        // No file eviction and no premature release of either allowance.
        #expect(try Data(contentsOf: file).count == 1550)
        try await budget.releaseAfterJoining(second)
        let result = try await budget.settleAfterJoining(first)
        #expect(result.logicalBytes == 1550)
        try await budget.close()
    }
    @Test func everyManagedRootIsLockedEvenWhenAnotherControlRootIsSelected() async throws {
        let f = try BudgetFixture(), budget = try f.open()
        #expect(throws: ChapterStorageBudgetError.alreadyOpen) {
            try ChapterArtifactStorageBudget(controlDirectory: f.roots[1], managedDirectories: [f.roots[1]],
                policy: .init(maximumManagedBytes: 1600, minimumAvailableBytes: 0))
        }
        try await budget.close()
        let reopened = try f.open(); try await reopened.close()
    }
    @Test func countDepthAndReservationLimitsFailClosedWithoutEviction() async throws {
        let f = try BudgetFixture()
        let child = f.roots[1].appendingPathComponent("a/b"); try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let keep = child.appendingPathComponent("keep"); try Data("keep".utf8).write(to: keep)
        let depth = try f.open(depth: 1)
        await #expect(throws: ChapterStorageBudgetError.inventoryLimit) { try await depth.inventory() }; try await depth.close()
        let count = try f.open(entries: 1)
        await #expect(throws: ChapterStorageBudgetError.inventoryLimit) { try await count.inventory() }; try await count.close()
        let slots = try f.open(reservations: 1)
        let token = try await slots.reserve(bytes: 10)
        await #expect(throws: ChapterStorageBudgetError.busy) { try await slots.reserve(bytes: 1) }
        try await slots.releaseAfterJoining(token); try await slots.close()
        #expect(try String(contentsOf: keep, encoding: .utf8) == "keep")
    }
    @Test func freeSpaceFloorAndOverflowNeverAdmitAReservation() async throws {
        let f = try BudgetFixture(), budget = try f.open(minimumFree: UInt64(Int64.max))
        await #expect(throws: ChapterStorageBudgetError.freeSpace) { try await budget.reserve(bytes: 1) }
        await #expect(throws: ChapterStorageBudgetError.capacity) { try await budget.reserve(bytes: .max) }
        try await budget.close()
    }
    @Test(arguments: [false, true]) func symlinkAndFifoAreNotFollowedOrOpened(_ fifo: Bool) async throws {
        let f = try BudgetFixture(), entry = f.roots[1].appendingPathComponent("unknown")
        if fifo { #expect(mkfifo(entry.path, 0o600) == 0) }
        else { try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: f.outside) }
        let budget = try f.open()
        await #expect(throws: ChapterStorageBudgetError.unsafeEntry) { try await budget.inventory() }
        var info = stat(); #expect(lstat(entry.path, &info) == 0)
        try await budget.close()
    }
    @Test func cancellationJoinsOwnedScanBeforeLocksCanBeReleased() async throws {
        let f = try BudgetFixture(), budget = try f.open(), pause = BudgetPause()
        await budget.pauseScanForTesting { await pause.pause() }
        let work = Task { try await budget.reserve(bytes: 1) }
        await pause.wait(); work.cancel()
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        #expect(throws: ChapterStorageBudgetError.alreadyOpen) { try f.open() }
        await pause.open()
        await #expect(throws: CancellationError.self) { try await work.value }
        try await budget.close()
        let reopened = try f.open(); try await reopened.close()
    }
    @Test func joinedProducerMayReleaseAllowanceWhileAnotherInventoryIsOwned() async throws {
        let f = try BudgetFixture(), budget = try f.open(), pause = BudgetPause()
        let token = try await budget.reserve(bytes: 1)
        await budget.pauseScanForTesting { await pause.pause() }
        let scan = Task { try await budget.inventory() }
        await pause.wait()
        try await budget.releaseAfterJoining(token)
        await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
        await pause.open(); _ = try await scan.value
        try await budget.close()
    }
    @Test(arguments: [false, true]) func settlementRevalidatesTicketAndCancellationAfterLastAwait(_ cancel: Bool) async throws {
        let f = try BudgetFixture(), budget = try f.open(), pause = BudgetPause()
        let token = try await budget.reserve(bytes: 1)
        await budget.pauseSettlementForTesting { await pause.pause() }
        let work = Task { try await budget.settleAfterJoining(token) }
        await pause.wait()
        if cancel { work.cancel() } else { try await budget.releaseAfterJoining(token) }
        await pause.open()
        if cancel {
            await #expect(throws: CancellationError.self) { try await work.value }
            await #expect(throws: ChapterStorageBudgetError.busy) { try await budget.close() }
            try await budget.releaseAfterJoining(token)
        } else {
            await #expect(throws: ChapterStorageBudgetError.staleReservation) { try await work.value }
        }
        try await budget.close()
    }
    @Test func replacedRootAndLockCannotRedirectAccountingOrDeleteUnknownData() async throws {
        let f = try BudgetFixture(), budget = try f.open()
        let old = f.root.appendingPathComponent("Old-Exports")
        try FileManager.default.moveItem(at: f.roots[1], to: old)
        try FileManager.default.createDirectory(at: f.roots[1], withIntermediateDirectories: false)
        await #expect(throws: ChapterStorageBudgetError.unsafeEntry) { try await budget.inventory() }
        try await budget.close()
        // Fresh scope over the replacements; all historical files remain.
        let next = try f.open(), lock = f.roots[0].appendingPathComponent("artifact-budget.lock")
        try FileManager.default.removeItem(at: lock); try Data("unknown".utf8).write(to: lock)
        await #expect(throws: ChapterStorageBudgetError.storage) { try await next.inventory() }
        try await next.close()
        #expect(try String(contentsOf: lock, encoding: .utf8) == "unknown")
    }
    @Test func staleTicketsAndNestedScopesReject() async throws {
        let f = try BudgetFixture(), budget = try f.open()
        let token = try await budget.reserve(bytes: 1)
        try await budget.releaseAfterJoining(token); try await budget.close()
        let reopened = try f.open()
        await #expect(throws: ChapterStorageBudgetError.staleReservation) { try await reopened.releaseAfterJoining(token) }
        try await reopened.close()
        #expect(throws: ChapterStorageBudgetError.invalidConfiguration) {
            try ChapterArtifactStorageBudget(controlDirectory: f.root, managedDirectories: [f.root, f.roots[0]],
                policy: .init(maximumManagedBytes: 1600, minimumAvailableBytes: 0))
        }
    }
}
