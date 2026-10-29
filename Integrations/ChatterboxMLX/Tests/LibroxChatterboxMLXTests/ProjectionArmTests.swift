#if os(macOS)
import XCTest
import Foundation
import MLX
@testable import LibroxChatterboxMLX

final class ProjectionArmTests: XCTestCase {
    private enum Injected: Error { case stop(Int) }
    private struct Outcome: Sendable {
        let attempted: Int
        let completed: Int
        let skipped: Int
        let accepted: Int
        let wroteReceipt: Bool
        let failedModule: String?
        let failed: Bool
    }
    private static func exercise(failureAt: Int?, cancelAfter: Int? = nil) throws -> Outcome {
        try Device.withDefaultDevice(.cpu) {
            let arm = ProjectionArm(mode: .eagerNative, budget: .init(), injectedFailure: { index in
                index == failureAt ? Injected.stop(index) : nil
            })
            arm.stage = "test"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let receipt = directory.appendingPathComponent("accepted.json")
            var failed = false
            do {
                _ = try arm.evaluate {
                    var x = MLXArray.ones([1, 1], dtype: .float16)
                    let w = MLXArray.ones([1, 1], dtype: .float16)
                    for index in 0..<210 {
                        x = arm.project(module: "projection\(index)", input: x, weight: w)
                        if index == cancelAfter { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                    return x
                }
                try Data("accepted".utf8).write(to: receipt)
            } catch { failed = true }
            return Outcome(attempted: arm.attempted, completed: arm.completedHelpers,
                skipped: arm.shortCircuits, accepted: arm.acceptedEvaluations,
                wroteReceipt: FileManager.default.fileExists(atPath: receipt.path),
                failedModule: arm.failure?.module, failed: failed)
        }
    }

    func testFirstMiddleLastFailuresCannotEvaluateOrAcceptTheRemainder() throws {
        for index in [0, 104, 209] {
            let result = try Self.exercise(failureAt: index)
            XCTAssertTrue(result.failed)
            XCTAssertEqual(result.attempted, index + 1)
            XCTAssertEqual(result.completed, index)
            XCTAssertEqual(result.skipped, 209 - index)
            XCTAssertEqual(result.accepted, 0)
            XCTAssertFalse(result.wroteReceipt)
            XCTAssertEqual(result.failedModule, "projection\(index)")
        }
    }

    func testActualMidRunCancellationShortCircuitsBeforeAnyFurtherHelper() async throws {
        let task = Task.detached { try Self.exercise(failureAt: nil, cancelAfter: 103) }
        let result = try await task.value
        XCTAssertTrue(result.failed)
        XCTAssertEqual(result.completed, 104)
        XCTAssertEqual(result.attempted, 105)
        XCTAssertEqual(result.skipped, 105)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertFalse(result.wroteReceipt)
        XCTAssertEqual(result.failedModule, "projection104")
    }

    func testCancellationAtEndOfEvaluationCannotBeAccepted() async {
        let task = Task.detached { () -> Bool in
            Device.withDefaultDevice(.cpu) {
                let arm = ProjectionArm(mode: .eagerNative, budget: .init(), afterEvaluation: {
                    withUnsafeCurrentTask { $0?.cancel() }
                })
                do {
                    _ = try arm.evaluate { MLXArray.ones([1, 1]) }
                    return false
                } catch {
                    return arm.acceptedEvaluations == 0 && arm.failure?.module == "after-evaluation"
                }
            }
        }
        let rejected = await task.value
        XCTAssertTrue(rejected)
    }

    func testCancellationBeforeConstructionNeverBuildsLogits() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task.detached { () -> Bool in
            for await _ in stream { }
            return Device.withDefaultDevice(.cpu) {
                let arm = ProjectionArm(mode: .eagerNative, budget: .init())
                var constructed = false
                do {
                    _ = try arm.evaluate { constructed = true; return MLXArray.ones([1, 1]) }
                    return false
                } catch { return !constructed && arm.attempted == 0 && arm.acceptedEvaluations == 0 }
            }
        }
        task.cancel(); continuation.finish()
        let stopped = await task.value
        XCTAssertTrue(stopped)
    }

    func testPreparedWeightsMatchUncachedHelperAcrossFixedInputLengths() throws {
        try Device.withDefaultDevice(.cpu) {
            var values = [Float16](repeating: 0, count: 1024 * 1024)
            for index in 0..<8 { values[index * 1024 + index] = Float16(index + 1) / 4 }
            let weight = MLXArray(values, [1024, 1024]), budget = CertifiedHalfProjection.Budget()
            let prepared = try CertifiedHalfProjection.prepare(weight: weight, budget: budget)
            for length in [1, 2] {
                let input = MLXArray((0..<(2 * length * 1024)).map { Float16(($0 % 7) - 3) / 4 }, [2, length, 1024])
                let cached = try CertifiedHalfProjection.evaluate(input: input, prepared: prepared, budget: budget)
                let uncached = try CertifiedHalfProjection.evaluate(input: input, weight: weight, budget: budget)
                XCTAssertEqual(cached.shape, uncached.shape)
                XCTAssertEqual(cached.values.map(\.bitPattern), uncached.values.map(\.bitPattern))
                XCTAssertEqual(cached.statistics.certified, uncached.statistics.certified)
                XCTAssertEqual(cached.statistics.exactFallback, uncached.statistics.exactFallback)
            }
        }
    }
}
#endif
