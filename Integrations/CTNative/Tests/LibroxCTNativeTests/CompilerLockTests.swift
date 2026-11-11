import Darwin
import Foundation
import Synchronization
import XCTest
@testable import LibroxCTNative

@MainActor final class CompilerLockTests: XCTestCase {
    private func root() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition())
    }

    func testUnrelatedKeysCanOwnCompilerLocksTogether() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0), entered = Mutex(0)
        let tasks = ["english", "spanish"].map { key in
            Task.detached {
                try CTCompilerLock.withLock(root: root, key: key) {
                    entered.withLock { $0 += 1 }; release.wait()
                }
            }
        }
        await waitUntil { entered.withLock { $0 } == 2 }
        release.signal(); release.signal()
        for task in tasks { try await task.value }
    }

    func testMatchingKeyWaitCanCancelBeforeOwnerReleases() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let release = DispatchSemaphore(value: 0), entered = Mutex(false)
        let owner = Task.detached {
            try CTCompilerLock.withLock(root: root, key: "same") {
                entered.withLock { $0 = true }; release.wait()
            }
        }
        await waitUntil { entered.withLock { $0 } }
        let started = Mutex(false), cancelled = Mutex(false), ran = Mutex(false)
        let waiting = Task.detached {
            do { try CTCompilerLock.withLock(root: root, key: "same", onWait: { started.withLock { $0 = true } }) { ran.withLock { $0 = true } } }
            catch is CancellationError { cancelled.withLock { $0 = true } }
        }
        await waitUntil { started.withLock { $0 } }
        waiting.cancel()
        await waitUntil { cancelled.withLock { $0 } }
        XCTAssertFalse(ran.withLock { $0 })
        release.signal()
        try await owner.value; try await waiting.value
        XCTAssertEqual(try CTCompilerLock.withLock(root: root, key: "same") { 7 }, 7)
    }

    func testLegacyExclusiveOwnerStillExcludesNewCompilerAndWaitCancels() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fd = open(root.appendingPathComponent(".compile.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let started = Mutex(false), cancelled = Mutex(false), ran = Mutex(false)
        let waiting = Task.detached {
            do { try CTCompilerLock.withLock(root: root, key: "new", onWait: { started.withLock { $0 = true } }) { ran.withLock { $0 = true } } }
            catch is CancellationError { cancelled.withLock { $0 = true } }
        }
        await waitUntil { started.withLock { $0 } }
        waiting.cancel()
        await waitUntil { cancelled.withLock { $0 } }
        XCTAssertFalse(ran.withLock { $0 })
        flock(fd, LOCK_UN)
        try await waiting.value
    }
}
