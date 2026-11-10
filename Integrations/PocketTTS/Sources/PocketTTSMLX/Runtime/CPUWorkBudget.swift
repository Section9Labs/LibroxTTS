import Foundation
import Darwin

/// Background audio execution has a CPU watchdog even when GPU is not used.
/// Account for process CPU time (including MLX's worker), and leave headroom
/// for playback/host work. No equations, samples or sampling settings change.
/// Frame callbacks are synchronous; sleeps are bounded to 50 ms with cancellation
/// checks. This runs on the engine actor, never on the UI thread.
public struct PocketCPUWorkBudget {
    /// Conservative legacy budget. This is not a guarantee against OS resource
    /// termination; watchdog limits depend on the device and execution context.
    public static let defaultFraction = 0.5
    private let started = ProcessInfo.processInfo.systemUptime
    private let cpuStarted = Self.cpuTime()
    let fraction: Double

    private init(fraction: Double) { self.fraction = fraction }

    static var watchdogPlatform: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// `fraction` nil skips library-inserted delays. iOS resource policies still
    /// apply. Otherwise clamped to 0.1…0.8 of one core's process CPU time.
    static func make(cpu: Bool, fraction: Double?, watchdogPlatform: Bool) -> Self? {
        guard cpu, watchdogPlatform, let fraction, fraction.isFinite else { return nil }
        return Self(fraction: min(0.8, max(0.1, fraction)))
    }

    public static func backgroundBudget(cpu: Bool, fraction: Double? = defaultFraction) -> Self? {
        make(cpu: cpu, fraction: fraction, watchdogPlatform: watchdogPlatform)
    }

    public func checkpoint() throws {
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
