import CryptoKit
import Darwin
import Foundation
import XCTest
import PocketTTSCoreML
import KokoroCatalog

/// Runs alone in a fresh process with real assets. Caller supplies no autorelease
/// pool between renders: the SDK must bound its own Foundation bridge lifetimes.
final class Release10LifetimeTests: XCTestCase {
    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
            task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
        } }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
    func testRepeatedStyledRendersBoundTemporaryMemory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let assets = env["LIBROX_10_LIFETIME_ASSETS"], let output = env["LIBROX_10_LIFETIME_OUTPUT"] else {
            throw XCTSkip("Opt-in isolated process memory regression")
        }
        let engine = PocketTTSCoreMLEngine(directory:URL(fileURLWithPath:assets))
        await engine.setCPUBudgetFraction(nil)
        var footprints: [UInt64] = [], reference: Data?
        for _ in 0..<24 {
            await engine.setRandomSeed(42)
            let audio = try await engine.synthesize("The door was open.",voiceID:"pocket-caro_davy-en-v1",deliveryStyle:.calm)
            let hash = audio.samples.withUnsafeBytes { Data(SHA256.hash(data:Data($0))) }
            if let reference { XCTAssertEqual(hash,reference) } else { reference = hash }
            footprints.append(footprint())
        }
        await engine.unload()
        let warm = footprints[5], peak = footprints.dropFirst(5).max()!
        XCTAssertLessThan(peak-warm,64*1_048_576,"Retained temporary memory grows across styled renders")
        try JSONSerialization.data(withJSONObject:["footprints":footprints,"maximumGrowthAfterWarmup":peak-warm,"limitBytes":64*1_048_576,"exactRepeatedPCM":true],options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:output),options:.atomic)
    }
}
