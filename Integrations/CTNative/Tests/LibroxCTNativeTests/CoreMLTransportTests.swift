import CoreML
import Foundation
import Testing
@testable import LibroxCTNative

@Test func featureSnapshotsRespectStridesAndRetainInputBytes() throws {
    let original = try CTTensor([Float(1), -0, 3, 4], shape: [1, 2, 2])
    let feature = try CTCoreMLGraph.feature(original)
    #expect(try CTCoreMLGraph.tensor(feature).data == original.data)
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: 6)
    storage.initialize(from: [1, 2, 999, 3, 4, 999], count: 6)
    let strided = try MLMultiArray(dataPointer: storage, shape: [1, 2, 2], dataType: .float32,
                                  strides: [6, 3, 1], deallocator: { $0.deallocate() })
    #expect(try CTCoreMLGraph.tensor(MLFeatureValue(multiArray: strided)).floats() == [1, 2, 3, 4])
}

@Test func textPaddingPreservesRowsAndMasksWithoutChangingLatentLengths() throws {
    let storage = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    storage.initialize(from: [1, 99, 2, 99, 3, 99, 4, 99], count: 8)
    let source = try MLMultiArray(dataPointer: storage, shape: [1, 2, 2], dataType: .float32,
                                 strides: [8, 4, 2], deallocator: { $0.deallocate() })
    let padded = try CTCoreMLGraph.paddedText(MLFeatureValue(multiArray: source), capacity: 4)
    #expect(try CTCoreMLGraph.tensor(padded).floats() == [1, 2, 0, 0, 3, 4, 0, 0])
    let ids = try CTCoreMLGraph.feature(CTTensor([Int64(5), 6], shape: [1, 2]))
    let tokens = try CTCoreMLGraph.paddedText(ids, capacity: 4).multiArrayValue!
    #expect((0..<4).map { tokens[$0].intValue } == [5, 6, 0, 0])
    #expect(throws: CTError.self) { try CTCoreMLGraph.paddedText(ids, capacity: 1) }
    for length in 1...431 { #expect(try !CTGenerator.functionName(for: length).isEmpty) }
    #expect(throws: CTError.self) { try CTGenerator.functionName(for: 0) }
    #expect(throws: CTError.self) { try CTGenerator.functionName(for: 432) }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_TEST_ASSETS"] != nil &&
               ProcessInfo.processInfo.environment["CT_TEST_FIXTURES"] != nil))
func tracingDoesNotChangeTheRetainedFeaturePipeline() async throws {
    let assets = try #require(ProcessInfo.processInfo.environment["CT_TEST_ASSETS"])
    let fixtures = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CT_TEST_FIXTURES"]))
    struct Fixture: Decodable { let id: String; let text: String; let language: String }
    struct Layout: Decodable { let shape: [Int]; let dtype: CTTensor.Kind }
    let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixtures.appendingPathComponent("cases.json")))
    let engine = CTEngine(directory: URL(fileURLWithPath: assets))
    try await engine.load()
    for item in cases {
        let directory = fixtures.appendingPathComponent(item.id)
        let layout = try JSONDecoder().decode([String: Layout].self, from: Data(contentsOf: directory.appendingPathComponent("layout.json")))
        let spec = try #require(layout["initial_latent"])
        let noise = try CTTensor(shape: spec.shape, kind: spec.dtype, data: Data(contentsOf: directory.appendingPathComponent("initial_latent.bin")))
        let traced = try await engine.synthesize(item.text, language: item.language, initialNoise: noise, captureTrace: true)
        let normal = try await engine.synthesize(item.text, language: item.language, initialNoise: noise)
        #expect(normal.trace.isEmpty)
        #expect(try CTTensor(normal.samples, shape: [normal.samples.count]).data == traced.trace["waveform"]?.data)
    }
    await engine.unload()
}
