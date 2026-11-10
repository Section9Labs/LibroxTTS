// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import Darwin
import MLX

/// A recoverable admission failure, never a replacement for CancellationError.
public enum PocketTTSResourceError: LocalizedError, Sendable, Equatable {
    case memory(availableBytes: UInt64, requiredBytes: UInt64)
    case thermal

    public var errorDescription: String? {
        switch self {
        case .memory: "Max needs more available memory. Pause other work and try again."
        case .thermal: "Your device needs to cool down before Max can continue."
        }
    }
}

/// Contains no source text, speaker names, or book identifiers.
public struct PocketTTSResourceSnapshot: Sendable, Codable {
    public let phase: String
    public let availableBytes: UInt64?
    public let footprintBytes: UInt64
    public let activeBytes: Int
    public let cacheBytes: Int
    public let peakBytes: Int
    public let thermalState: Int
    public let backend: String
    public let samplerSteps: Int?
    public let tokenCount: Int?
    public let frameIndex: Int?
    public let uptime: TimeInterval
}

/// Checks process headroom, not physical RAM or an allowed device list. This is
/// conservative admission, not a guarantee against jetsam between checkpoints.
struct PocketTTSResourceMonitor {
    static let reserveBytes: UInt64 = 128 * 1_048_576
    static let cacheHighWater = 256 * 1_048_576
    static func loadReservation(fileBytes: UInt64) -> UInt64 {
        // Hosted weights are BF16. Sequential tensor conversion avoids a
        // whole-checkpoint overlap; reserve FP32 residency plus the independent
        // headroom for the current source tensor and runtime allocations.
        let result = fileBytes.multipliedReportingOverflow(by: 2)
        return result.overflow ? UInt64.max : result.partialValue
    }
    let backend: String
    var samplerSteps: Int? = nil
    var tokenCount: Int? = nil
    var frameIndex: Int? = nil
    var observe: (@Sendable (PocketTTSResourceSnapshot) -> Void)?

    static func check(available: UInt64?, required: UInt64, criticalThermal: Bool) throws {
        try Task.checkCancellation()
        if criticalThermal { throw PocketTTSResourceError.thermal }
        if let available, available < required {
            throw PocketTTSResourceError.memory(availableBytes: available, requiredBytes: required)
        }
    }

    func checkpoint(_ phase: String, additionalBytes: UInt64 = 0) throws {
        try Task.checkCancellation()
        // Recycle between bounded operations, before deciding admission. Do not
        // change process-global MLX limits belonging to other engine instances.
        if Memory.cacheMemory > Self.cacheHighWater { Memory.clearCache() }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let sum = Self.reserveBytes.addingReportingOverflow(additionalBytes)
        let required = sum.overflow ? UInt64.max : sum.partialValue
        var available = UInt64(os_proc_available_memory())
        // Reclaim reusable allocations before rejecting otherwise viable work.
        if available < required {
            Memory.clearCache()
            available = UInt64(os_proc_available_memory())
        }
        // Full Mach/allocator diagnostics are opt-in; admission needs only the
        // inexpensive available-process-budget and thermal readings.
        if let observe { observe(snapshot(phase)) }
        try Self.check(available: available, required: required,
                       criticalThermal: ProcessInfo.processInfo.thermalState == .critical)
        #else
        // Avoid Mach/allocator diagnostics on desktop when none were requested.
        if let observe { observe(snapshot(phase)) }
        try Task.checkCancellation()
        #endif
    }

    func snapshot(_ phase: String) -> PocketTTSResourceSnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let available: UInt64? = UInt64(os_proc_available_memory())
        #else
        let available: UInt64? = nil
        #endif
        return .init(phase: phase, availableBytes: available,
                     footprintBytes: result == KERN_SUCCESS ? info.phys_footprint : 0,
                     activeBytes: Memory.activeMemory, cacheBytes: Memory.cacheMemory,
                     peakBytes: Memory.peakMemory,
                     thermalState: ProcessInfo.processInfo.thermalState.rawValue, backend: backend,
                     samplerSteps: samplerSteps, tokenCount: tokenCount, frameIndex: frameIndex,
                     uptime: ProcessInfo.processInfo.systemUptime)
    }
}

/// Shared admission checks for acoustic backends; this does not load a model.
public enum PocketTTSResourceChecks {
    public static func checkpoint(_ phase: String, backend: String, samplerSteps: Int?,
                                  frameIndex: Int? = nil,
                                  observer: (@Sendable (PocketTTSResourceSnapshot) -> Void)? = nil) throws {
        try PocketTTSResourceMonitor(backend: backend, samplerSteps: samplerSteps,
                                     frameIndex: frameIndex, observe: observer).checkpoint(phase)
    }
}
