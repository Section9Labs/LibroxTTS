#if os(macOS)
import Foundation
import Dispatch
import Darwin

/// Owns exactly the Process it starts. Cancellation never waits indefinitely:
/// one-second SIGTERM grace, then owned-child SIGKILL and one-second join grace.
final class ReferenceOwnedChild {
    enum Failure: Error { case cleanup(Int32) }
    private(set) var usedSIGKILL = false
    func run(_ child: Process, check: () throws -> Void) throws -> Int32 {
        var started = false
        do {
            try check()
            try child.run(); started = true
            while child.isRunning { try check(); Thread.sleep(forTimeInterval: 0.01) }
            child.waitUntilExit() // Already observed terminated; this does not block.
            try check()
            return child.terminationStatus
        } catch {
            if started { try cleanup(child) }
            throw error
        }
    }
    private func waitBounded(_ child: Process) {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while child.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    private func cleanup(_ child: Process) throws {
        if child.isRunning { child.terminate(); waitBounded(child) }
        if child.isRunning {
            usedSIGKILL = true
            // This is the same still-running child Process started above;
            // no stored historical PID or unrelated process is targeted.
            let result = Darwin.kill(child.processIdentifier, SIGKILL)
            guard result == 0 || errno == ESRCH else { throw Failure.cleanup(child.processIdentifier) }
            waitBounded(child)
        }
        guard !child.isRunning else { throw Failure.cleanup(child.processIdentifier) }
        child.waitUntilExit()
    }
}
#endif
