import MLX
import XCTest
@testable import PocketTTSMLX

final class RotaryExecution10Tests: XCTestCase {
    func testMeasurePrivateTermReuse() throws {
        guard let path = ProcessInfo.processInfo.environment["LIBROX_10_ROTARY_OUTPUT"] else { throw XCTSkip("Opt-in rotary ablation") }
        PocketTestMetal.configure()
        var rows: [[String: Any]] = []
        for device in [Device.cpu,.gpu] {
            Device.withDefaultDevice(device) {
                let old = PocketRotaryEmbedding(), new = PocketRotaryEmbedding()
                new.enableEngineExecution()
                let inputs = (0..<6).map { layer in MLXArray((0..<1024).map { Float(($0 + layer) % 73) / 17 },[1,1,16,64]) }
                func run(_ module: PocketRotaryEmbedding, positions: Int) {
                    for offset in 0..<positions {
                        for input in inputs {
                            let result = module(input,input,offset:offset)
                            eval(result.0,result.1)
                        }
                    }
                }
                run(old,positions:8); run(new,positions:8)
                for candidate in [false,true,true,false] {
                    let start = ProcessInfo.processInfo.systemUptime
                    run(candidate ? new : old,positions:64)
                    rows.append(["device":String(describing:device),"candidate":candidate,
                        "seconds":ProcessInfo.processInfo.systemUptime-start,"positions":64,"layers":6])
                }
            }
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:path),options:.atomic)
    }

    func testPrivateTermsPreserveBitsAcrossPositionsAndDevices() {
        PocketTestMetal.configure()
        let old = PocketRotaryEmbedding(), new = PocketRotaryEmbedding()
        new.enableEngineExecution()
        XCTAssertEqual(old.parameters().flattened().map(\.0), new.parameters().flattened().map(\.0))
        for device in [Device.cpu,.gpu,.cpu] {
            Device.withDefaultDevice(device) {
                for (time,offset) in [(1,0),(7,127),(1,128),(1,128),(16,512),(1,9)] {
                    let q = MLXArray((0..<(time*2*64)).map { Float($0 % 137) * 0.031 },[1,time,2,64])
                    let k = q * 0.25
                    let reference = old(q,k,offset:offset), candidate = new(q,k,offset:offset)
                    XCTAssertEqual(reference.0.asArray(Float.self).map(\.bitPattern),candidate.0.asArray(Float.self).map(\.bitPattern))
                    XCTAssertEqual(reference.1.asArray(Float.self).map(\.bitPattern),candidate.1.asArray(Float.self).map(\.bitPattern))
                }
            }
        }
    }
}
