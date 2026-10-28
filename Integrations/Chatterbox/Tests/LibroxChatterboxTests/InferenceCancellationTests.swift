import Synchronization
import Testing
@testable import ChatterboxCoreML

@Test func cancellationBeforePredictionDoesNotStartWork() async {
    let calls = Mutex(0)
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try trapping("cancel-before-predict") {
            calls.withLock { $0 += 1 }
            return 42
        }
    }
    do {
        _ = try await task.value
        Issue.record("Cancelled prediction unexpectedly completed")
    } catch is CancellationError {
        #expect(calls.withLock { $0 } == 0)
    } catch { Issue.record("Expected cancellation, got \(error)") }
}

@Test func cancellationDuringPredictionStopsBeforeNextStage() async {
    let calls = Mutex(0)
    let task = Task {
        _ = try trapping("in-flight-predict") {
            calls.withLock { $0 += 1 }
            // Model-free stand-in for cancellation arriving during a synchronous
            // accelerator call: that one call completes, then no next stage runs.
            withUnsafeCurrentTask { $0?.cancel() }
            return 42
        }
        return try trapping("must-not-start-next-predict") {
            calls.withLock { $0 += 1 }
            return 99
        }
    }
    do {
        _ = try await task.value
        Issue.record("Cancelled pipeline unexpectedly completed")
    } catch is CancellationError {
        #expect(calls.withLock { $0 } == 1)
    } catch { Issue.record("Expected cancellation, got \(error)") }
}

@Test func uncancelledPredictionKeepsResult() throws {
    let value = try trapping("normal-predict") { [Float(bitPattern: 0x3f123456)] }
    #expect(value[0].bitPattern == 0x3f123456)
}
