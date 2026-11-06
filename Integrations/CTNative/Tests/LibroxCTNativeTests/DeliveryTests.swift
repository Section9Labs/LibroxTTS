import Foundation
import Testing
@testable import LibroxCTNative

@Test func constantGainAndResamplingNeverClipNativeOvers() throws {
    let native = (0..<44_100).map { Float(2 * sin(2 * Double.pi * 440 * Double($0) / 44_100)) }
    let delivered = try CTDelivery.prepare(native, sampleRate: 44_100)
    #expect(delivered.samples.count == native.count)
    #expect(delivered.samples.allSatisfy { $0.isFinite && abs($0) < 1 })
    #expect(abs(try CTDelivery.integratedLoudness(delivered.samples) + 24) < 0.0001)
    let ratio = Float(pow(10, delivered.gainDB / 20))
    #expect(zip(native, delivered.samples).allSatisfy { abs($1 - $0 * ratio) < 1e-6 })
    let resampled = try CTDelivery.prepare(native)
    #expect(abs(resampled.samples.count - 24_000) <= 1)
    #expect(resampled.sampleRate == 24_000)
    #expect(throws: CTError.self) { try CTDelivery.prepare([.nan]) }
    #expect(throws: CTError.self) { try CTDelivery.prepare([0, 0, 0]) }
}
@Test func tensorRejectsMalformedFixtureAndOverflow() throws {
    #expect(throws: CTError.self) { try CTTensor(shape: [Int.max, 2], kind: .float32, data: Data()) }
    #expect(throws: CTError.self) { try CTTensor(shape: [2], kind: .int64, data: Data(repeating: 0, count: 8)) }
}
