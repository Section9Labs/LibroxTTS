import Foundation
import Darwin

/// Background audio execution has a CPU watchdog even when GPU is not used.
/// Account for process CPU time (including MLX's worker), and leave headroom
/// for playback/host work. No equations, samples or sampling settings change.
/// Frame callbacks are synchronous; sleeps are bounded to 50 ms with cancellation
/// checks. This runs on the engine actor, never on the UI thread.
struct PocketCPUWorkBudget {
    private let started = ProcessInfo.processInfo.systemUptime
    private let cpuStarted = Self.cpuTime()
    private let fraction = 0.5

    static func backgroundBudget(cpu: Bool) -> Self? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        cpu ? Self() : nil
        #else
        nil
        #endif
    }

    func checkpoint() throws {
        while true {
            try Task.checkCancellation()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let required = max(0, Self.cpuTime() - cpuStarted) / fraction
            let remaining = required - elapsed
            guard remaining > 0.005 else { return }
            Thread.sleep(forTimeInterval: min(0.05, remaining))
        }
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
