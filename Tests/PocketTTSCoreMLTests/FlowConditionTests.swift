import CoreML
import XCTest
@testable import PocketTTSCoreML

final class FlowConditionTests: XCTestCase {
    func testPackedOutputUsesSameStorageAndRetainsOwnerUntilPredictionFinishes() throws {
        weak var owner: MLMultiArray?
        try autoreleasepool {
            let condition: MLMultiArray = try autoreleasepool {
                let source = try PocketTTSCoreMLEngine.floats(
                    (0..<1024).map { $0 == 0 ? -Float.zero : Float($0) }, shape: [1, 1, 1024])
                owner = source
                let view = try PocketTTSCoreMLEngine.flowCondition(source)
                XCTAssertEqual(view.dataPointer, source.dataPointer)
                return view
            }
            // The source's creation pool has drained; only the view owns it.
            XCTAssertNotNil(owner)
            XCTAssertEqual(condition.shape, [1, 1024])
            XCTAssertEqual(condition[0].floatValue.bitPattern, (-Float.zero).bitPattern)
            XCTAssertEqual(condition[1023].floatValue, 1023)
        }
        XCTAssertNil(owner)
    }

    func testAlreadyCompatibleOutputReturnsSameArray() throws {
        let source = try PocketTTSCoreMLEngine.floats([Float](repeating: 1, count: 1024), shape: [1, 1024])
        XCTAssertTrue(try PocketTTSCoreMLEngine.flowCondition(source) === source)
    }

    func testStridedOutputsCopyLogicalValuesWithoutPadding() throws {
        let layouts: [[NSNumber]] = [[1056, 33, 1], [2048, 64, 2]]
        for strides in layouts {
            let memory = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
            memory.initialize(repeating: -999, count: 2048)
            for row in 0..<32 { for column in 0..<32 {
                memory[row * strides[1].intValue + column * strides[2].intValue] = Float(row * 32 + column)
            } }
            let source = try MLMultiArray(dataPointer: memory, shape: [1, 32, 32], dataType: .float32,
                strides: strides, deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
            let condition = try PocketTTSCoreMLEngine.flowCondition(source)
            XCTAssertEqual(condition.shape, [1, 1024])
            XCTAssertNotEqual(condition.dataPointer, source.dataPointer)
            XCTAssertEqual(PocketTTSCoreMLEngine.values(condition), (0..<1024).map(Float.init))
        }
    }

    func testMalformedConditionIsRejected() throws {
        let short = try MLMultiArray(shape: [1, 32], dataType: .float32)
        let double = try MLMultiArray(shape: [1, 1024], dataType: .double)
        for source in [short, double] {
            XCTAssertThrowsError(try PocketTTSCoreMLEngine.flowCondition(source)) {
                guard case PocketTTSCoreMLEngine.Failure.invalidShape = $0 else {
                    return XCTFail("Expected invalidShape: \($0)")
                }
            }
        }
    }

    func testTransportMicrobenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["LIBROX_07_TENSOR_BENCHMARK"] else {
            throw XCTSkip("Set an evidence destination to run the transport microbenchmark")
        }
        let source = try PocketTTSCoreMLEngine.floats((0..<1024).map(Float.init), shape: [1, 1, 1024])
        let iterations = 20_000
        func measure(copy: Bool) throws -> Double {
            var checksum: Double = 0
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<iterations {
                try autoreleasepool {
                    let value = try copy
                        ? PocketTTSCoreMLEngine.floats(PocketTTSCoreMLEngine.values(source), shape: [1, 1024])
                        : PocketTTSCoreMLEngine.flowCondition(source)
                    checksum += Double(value[1023].floatValue)
                }
            }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(checksum, Double(iterations * 1023))
            return seconds
        }
        _ = try measure(copy: true); _ = try measure(copy: false)
        var copied: [Double] = [], shared: [Double] = []
        for trial in 0..<5 {
            if trial.isMultiple(of: 2) {
                copied.append(try measure(copy: true)); shared.append(try measure(copy: false))
            } else {
                shared.append(try measure(copy: false)); copied.append(try measure(copy: true))
            }
        }
        let report: [String: Any] = ["iterations": iterations, "copySeconds": copied, "viewSeconds": shared,
            "copyMedianSeconds": copied.sorted()[2], "viewMedianSeconds": shared.sorted()[2],
            "speedup": copied.sorted()[2] / shared.sorted()[2],
            "removedPayloadBytesPerCondition": 2 * 1024 * MemoryLayout<Float>.size,
            "scope": "Host transport only, synthetic contiguous Float32 [1,1,1024]; no inference or RSS measurement"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
