#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import Testing
import MLX
import MLXFast
import Cmlx
@testable import LibroxChatterboxMLX

/// Opt-in diagnostic, no models or audio. The internal C query does not schedule
/// work; it can detach an already completed event, so it is not side-effect-free.
struct DenseCacheAvailabilityTests {
    private struct Observation: Codable {
        let device: String
        let offset, capacity: Int
        let before, after: [Bool]
    }
    private struct Report: Codable { let completed: Bool; let observations: [Observation] }
    private enum ObservationError: Error { case control }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHATTERBOX_TOY_METALLIB"] != nil, "Explicit tiny diagnostic only"))
    func parentAvailabilityAfterAttention() throws {
        guard let runtimePath = ProcessInfo.processInfo.environment["CHATTERBOX_TOY_METALLIB"],
              let reportPath = ProcessInfo.processInfo.environment["CHATTERBOX_TOY_REPORT"] else { return }
        let began = ContinuousClock.now
        let fd = Darwin.open(runtimePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        try #require(fd >= 0)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        try #require(fstat(fd, &info) == 0)
        try #require(info.st_mode & S_IFMT == S_IFREG && info.st_size == 2_401_016)
        let data = try file.read(upToCount: 2_401_017) ?? Data()
        try #require(data.count == 2_401_016)
        try #require(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() ==
                     "282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f")
        try #require(!FileManager.default.fileExists(atPath: reportPath))
        let runtimeStatus = runtimePath.withCString { mlx_metal_set_metallib_path($0) }
        try #require(runtimeStatus == 0)
        var observations: [Observation] = []
        var complete = false
        func write(_ completed: Bool) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Report(completed: completed, observations: observations))
                .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        defer { if !complete { try? write(false) } }
        func health() throws {
            try Task.checkCancellation()
            guard began.duration(to: .now) < .seconds(10), Memory.activeMemory < 128 * 1024 * 1024,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled,
                  ProcessInfo.processInfo.thermalState != .serious,
                  ProcessInfo.processInfo.thermalState != .critical else { throw ObservationError.control }
        }
        for (name, device) in [("cpu", Device.cpu), ("gpu", Device.gpu)] {
            try Device.withDefaultDevice(device) {
                // Positive observation control: an unexecuted graph is not made
                // available by the query itself, even after a repeated query.
                let lazy = exp(MLXArray([Float(0.25), 0.5]))
                let first = try available(lazy), second = try available(lazy)
                guard !first, !second else { throw ObservationError.control }
                eval(lazy)
                guard try available(lazy) else { throw ObservationError.control }
                let cache = KVCache()
                for count in [255, 1, 1] {
                    try Task.checkCancellation()
                    try #require(began.duration(to: .now) < .seconds(10))
                    try #require(!ProcessInfo.processInfo.isLowPowerModeEnabled)
                    try #require(ProcessInfo.processInfo.thermalState != .serious && ProcessInfo.processInfo.thermalState != .critical)
                    let input = MLXArray.ones([2, 16, count, 64], dtype: .float16)
                    let active = cache.update(keys: input, values: input * Float(0.5))
                    let parents = cache.retainedArrays
                    try #require(parents.count == 2)
                    let before = try parents.map(available)
                    let q = MLXArray.ones([2, 16, 1, 64], dtype: .float32)
                    let attended = MLXFast.scaledDotProductAttention(queries: q,
                        keys: active.0.asType(.float32), values: active.1.asType(.float32), scale: 0.125, mask: .none)
                    // The only evaluation preceding the observation is of the
                    // consumer, exactly as the decoder evaluates its logits.
                    eval(attended)
                    let after = try parents.map(available)
                    observations.append(.init(device: name, offset: cache.offset,
                        capacity: parents[0].dim(2), before: before, after: after))
                    try write(false)
                    try health()
                    guard after.allSatisfy({ $0 }) else { throw ObservationError.control }
                    try #require(all(isFinite(attended)).item(Bool.self))
                }
            }
        }
        try #require(observations.map(\.offset) == [255, 256, 257, 255, 256, 257])
        try #require(observations.map(\.capacity) == [256, 256, 512, 256, 256, 512])
        try health()
        try write(true)
        complete = true
    }
    private func available(_ array: MLXArray) throws -> Bool {
        var result = false
        try #require(_mlx_array_is_available(&result, array.ctx) == 0)
        return result
    }
}
#endif
