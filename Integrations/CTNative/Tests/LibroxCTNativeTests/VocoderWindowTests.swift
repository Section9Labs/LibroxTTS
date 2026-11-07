import CoreML
import Foundation
import Testing
@testable import LibroxCTNative

@Test func vocoderWindowsCoverEverySampleWithBoundedContext() throws {
    for length in 1...431 {
        let windows = try CTVocoderWindows.plan(length: length)
        #expect(windows.flatMap { Array($0.output) } == Array(0..<length))
        for window in windows {
            #expect(window.input.count <= CTVocoderWindows.maximumInputLength)
            #expect(window.input.lowerBound == 0 || window.output.lowerBound - window.input.lowerBound == 24)
            #expect(window.input.upperBound == length || window.input.upperBound - window.output.upperBound == 24)
            #expect(window.crop.count == window.output.count * 3_072)
        }
    }
    #expect(throws: CTError.self) { try CTVocoderWindows.plan(length: 0) }
    #expect(throws: CTError.self) { try CTVocoderWindows.plan(length: 432) }
}

@Test func vocoderSlicePreservesChannelsAndStridedStorage() throws {
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: 144 * 12)
    storage.initialize(repeating: -1, count: 144 * 12)
    for row in 0..<144 { for column in 0..<6 { storage[row * 12 + column * 2] = Float(row * 100 + column) } }
    let source = try MLMultiArray(dataPointer: storage, shape: [1, 144, 6], dataType: .float32,
        strides: [1728, 12, 2], deallocator: { $0.deallocate() })
    let result = try CTVocoderWindows.slice(MLFeatureValue(multiArray: source), range: 2..<5)
    #expect(try CTCoreMLGraph.tensor(result).floats() == (0..<144).flatMap { row in (2..<5).map { Float(row * 100 + $0) } })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_TEST_ASSETS"] != nil))
func boundedVocoderMatchesWholePassageCoreML() throws {
    let assets = try #require(ProcessInfo.processInfo.environment["CT_TEST_ASSETS"])
    for backend in [CTEngine.Backend.coreMLCPU, .coreMLGPUHeavy] {
        let graph = try CTCoreMLGraph(package: URL(fileURLWithPath: assets).appendingPathComponent("coreml/vocoder.mlpackage"), backend: backend)
        for length in [77, 113, 129, 265, 431] {
            // Deterministic nonzero input exercises every seam and both natural edges.
            let values = (0..<(144 * length)).map { Float(sin(Double($0) * 0.719) * cos(Double($0) * 0.117)) }
            let latent = try CTCoreMLGraph.feature(CTTensor(values, shape: [1, 144, length]))
            let whole = try CTCoreMLGraph.tensor(graph.predict(["latent": latent])).floats()
            let bounded = try CTVocoderWindows.render(latent) { try graph.predict(["latent": $0]) }
            #expect(bounded.count == whole.count)
            let maxError = zip(whole, bounded).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            #expect(maxError < 0.000_01, "\(backend), length \(length), error \(maxError)")
            print("CT_VOCODER_EQUIVALENCE \(backend) length=\(length) maxError=\(maxError)")
        }
    }
}
