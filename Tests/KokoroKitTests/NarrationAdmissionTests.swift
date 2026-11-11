import XCTest
import Synchronization
@testable import LibroxTTS

@MainActor final class NarrationAdmissionTests: XCTestCase {
    private func waitForQueue(_ admission: NarrationAdmission, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while admission.queuedCount != count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(admission.queuedCount, count)
    }

    func testSurvivingRequestsAreFIFOAndMutuallyExclusive() async throws {
        let admission = NarrationAdmission()
        let order = Mutex<[Int]>([])
        await admission.acquire()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<8 {
            tasks.append(Task {
                await admission.acquire()
                order.withLock { $0.append(index) }
                admission.release()
            })
            try await waitForQueue(admission, count: index + 1)
        }
        XCTAssertTrue(order.withLock { $0.isEmpty })
        admission.release()
        for task in tasks { await task.value }
        XCTAssertEqual(order.withLock { $0 }, Array(0..<8))
        XCTAssertEqual(admission.queuedCount, 0)
    }

    func testCancelledUnloadStillJoinsRetirement() async throws {
        let admission = NarrationAdmission()
        let renderer = NarrationRenderer(compactDirectory: .temporaryDirectory, admission: admission)
        let completed = Mutex(false)
        await admission.acquire()
        let unload = Task { await renderer.unload(); completed.withLock { $0 = true } }
        try await waitForQueue(admission, count: 1)
        unload.cancel()
        XCTAssertFalse(completed.withLock { $0 })
        XCTAssertEqual(admission.queuedCount, 1)
        admission.release()
        await unload.value
        XCTAssertTrue(completed.withLock { $0 })
        await admission.acquire()
        admission.release()
    }

    func testRenderFailureReleasesAdmissionForLaterCleanup() async throws {
        let admission = NarrationAdmission()
        let renderer = NarrationRenderer(compactDirectory: .temporaryDirectory, admission: admission)
        let unit = BookNarrationUnit(sourceText: "Hello.", sourceRange: NSRange(location: 0, length: 6),
                                     narratorID: "pocket-caro_davy-en-v1", boundaryAfter: .sentence)
        do { _ = try await renderer.render(unit); XCTFail("Unloaded renderer succeeded") }
        catch NarrationRenderer.RenderError.invalidAudio {}
        await renderer.unload()
        XCTAssertEqual(admission.queuedCount, 0)
    }

    func testQueuedRenderCancelsBeforeActiveOwnerFinishes() async throws {
        let admission = NarrationAdmission()
        let renderer = NarrationRenderer(compactDirectory: .temporaryDirectory, admission: admission)
        let unit = BookNarrationUnit(sourceText: "Hello.", sourceRange: NSRange(location: 0, length: 6),
                                     narratorID: "pocket-caro_davy-en-v1", boundaryAfter: .sentence)
        await admission.acquire()
        let cancelled = Mutex(false)
        let render = Task {
            do { _ = try await renderer.render(unit); XCTFail("Cancelled request rendered") }
            catch is CancellationError { cancelled.withLock { $0 = true } }
            catch { XCTFail("Wrong error: \(error)") }
        }
        try await waitForQueue(admission, count: 1)
        render.cancel()
        let deadline = ContinuousClock.now + .seconds(3)
        while !cancelled.withLock({ $0 }), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(cancelled.withLock { $0 }, "Cancellation waited for the active owner")
        XCTAssertEqual(admission.queuedCount, 0)
        admission.release()
        await render.value
    }

    func testCancellationRemovesMiddleWaiterAndPreservesFIFO() async throws {
        let admission = NarrationAdmission(), order = Mutex<[Int]>([])
        await admission.acquire()
        var tasks: [Task<Void, Never>] = []
        for index in 0..<5 {
            tasks.append(Task {
                do {
                    try await admission.acquireCancellable()
                    defer { admission.release() }
                    order.withLock { $0.append(index) }
                } catch is CancellationError {} catch { XCTFail("\(error)") }
            })
            try await waitForQueue(admission, count: index + 1)
        }
        tasks[2].cancel()
        try await waitForQueue(admission, count: 4)
        admission.release()
        for task in tasks { await task.value }
        XCTAssertEqual(order.withLock { $0 }, [0, 1, 3, 4])
    }

    func testCancellationRacingAdmissionNeverStrandsOwnership() async throws {
        for _ in 0..<200 {
            let admission = NarrationAdmission()
            await admission.acquire()
            let waiter = Task {
                do { try await admission.acquireCancellable(); admission.release() }
                catch is CancellationError {} catch { XCTFail("\(error)") }
            }
            try await waitForQueue(admission, count: 1)
            let release = Task.detached { admission.release() }
            waiter.cancel()
            await release.value
            await waiter.value
            XCTAssertEqual(admission.queuedCount, 0)
            try await admission.acquireCancellable()
            admission.release()
        }
    }

    func testCancellationBeforeRegistrationDoesNotAcquire() async throws {
        let start = NarrationAdmission(), admission = NarrationAdmission()
        await start.acquire()
        let waiter = Task {
            await start.acquire(); start.release()
            do { try await admission.acquireCancellable(); admission.release(); XCTFail("Acquired after cancellation") }
            catch is CancellationError {} catch { XCTFail("\(error)") }
        }
        try await waitForQueue(start, count: 1)
        waiter.cancel(); start.release()
        await waiter.value
        XCTAssertEqual(admission.queuedCount, 0)
        try await admission.acquireCancellable(); admission.release()
    }
}
