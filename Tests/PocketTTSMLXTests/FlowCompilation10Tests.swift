import Foundation
import MLX
import XCTest
@testable import PocketTTSMLX

/// Research receipt only. Numerical differences reject compilation; this never
/// enables a compiled graph in the shipping engine or relaxes its audio gate.
final class FlowCompilation10Tests: XCTestCase {
    func testRecordCompiledFlowExactness() throws {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["LIBROX_10_COMPILE_ASSETS"], let output = env["LIBROX_10_COMPILE_OUTPUT"] else {
            throw XCTSkip("Opt-in graph compilation experiment with pinned weights")
        }
        PocketTestMetal.configure()
        var rows: [[String: Any]] = []
        for device in [Device.cpu, .gpu] {
            try Device.withDefaultDevice(device) {
                let model = try PocketTTSModel.fromModelDirectory(URL(fileURLWithPath: root).appendingPathComponent("en"))
                let flow = model.flow_lm.flow_net
                let compiled = MLX.compile(inputs: [flow]) { (a: [MLXArray]) in [flow(a[0], a[1], a[2], a[3])] }
                for trial in 0..<8 {
                    let condition = MLXArray((0..<model.flow_lm.dim).map { Float(($0 * 17 + trial) % 97 - 48) / 13 }, [1,model.flow_lm.dim])
                    let noise = MLXArray((0..<model.flow_lm.ldim).map { Float(($0 * 7 + trial) % 31 - 15) / 11 }, [1,model.flow_lm.ldim])
                    let s = MLXArray([Float(trial)/8], [1,1]), t = MLXArray([Float(trial+1)/8], [1,1])
                    let start = ProcessInfo.processInfo.systemUptime
                    let old = flow(condition,s,t,noise).asArray(Float.self)
                    let ordinarySeconds = ProcessInfo.processInfo.systemUptime - start
                    let next = ProcessInfo.processInfo.systemUptime
                    let new = compiled([condition,s,t,noise])[0].asArray(Float.self)
                    let compiledSeconds = ProcessInfo.processInfo.systemUptime - next
                    XCTAssertEqual(old.count,new.count)
                    rows.append(["device":String(describing:device),"trial":trial,
                        "differingValues":zip(old,new).filter { $0.bitPattern != $1.bitPattern }.count,
                        "values":old.count,"ordinarySeconds":ordinarySeconds,"compiledSeconds":compiledSeconds,
                        "maximumAbsoluteDifference":zip(old,new).map { abs($0-$1) }.max() ?? 0])
                }
            }
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:output),options:.atomic)
    }
}
