import Foundation
import Testing
@testable import PocketTTSMLX

// Explicit CPU pacing remains available independently of playback scheduling.
// No budget value guarantees exemption from the OS's resource policies.

@Test func defaultBudgetIsHalfACore() {
    #expect(PocketCPUWorkBudget.defaultFraction == 0.5)
    #expect(PocketCPUWorkBudget.make(cpu: true, fraction: PocketCPUWorkBudget.defaultFraction,
                                     watchdogPlatform: true)?.fraction == 0.5)
}

@Test func unmeteredBudgetSkipsCheckpoints() {
    #expect(PocketCPUWorkBudget.make(cpu: true, fraction: nil, watchdogPlatform: true) == nil)
    #expect(PocketCPUWorkBudget.make(cpu: false, fraction: 0.5, watchdogPlatform: true) == nil)
    #expect(PocketCPUWorkBudget.make(cpu: true, fraction: 0.5, watchdogPlatform: false) == nil)
}

@Test func fractionIsClampedToSupportedRange() {
    #expect(PocketCPUWorkBudget.make(cpu: true, fraction: 2, watchdogPlatform: true)?.fraction == 0.8)
    #expect(PocketCPUWorkBudget.make(cpu: true, fraction: 0.01, watchdogPlatform: true)?.fraction == 0.1)
}

@Test func engineBudgetDefaultsAndCanBeUnmetered() async {
    let engine = PocketTTSEngine(directory: URL(fileURLWithPath: "/nonexistent"), backend: .cpu)
    #expect(await engine.cpuBudgetFraction == 0.5)
    await engine.setCPUBudgetFraction(nil)
    #expect(await engine.cpuBudgetFraction == nil)
    await engine.setCPUBudgetFraction(0.7)
    #expect(await engine.cpuBudgetFraction == 0.7)
}
