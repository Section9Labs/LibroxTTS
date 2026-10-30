import XCTest
@testable import ChatterboxMacAcousticAudit
#if os(macOS)
final class AcousticInventoryTests: XCTestCase {
    func testOnlyDeclaredExternalComponentsAreExcluded() throws {
        for key in ["t3.tfmr.weight", "ve.proj.weight", "s3gen.speaker_encoder.weight", "s3gen.tokenizer.weight"] {
            XCTAssertNil(try AcousticInventory.route(key).target)
        }
        for key in ["garbage.weight", "s3gen.unknown.weight", "s3gen.foo.flow.weight", "t3x.weight"] {
            XCTAssertThrowsError(try AcousticInventory.route(key))
        }
    }
    func testRegularMappingPreservesConvAndFeedForwardNesting() throws {
        let cases = [
            "s3gen.flow.decoder.estimator.down_blocks_0.transformer_1.attn.query_proj.weight": "decoder.estimator.down_blocks.0.transformer_blocks.1.attn1.to_q.weight",
            "s3gen.flow.decoder.estimator.mid_blocks_12.transformer_0.ff.layers.0.weight": "decoder.estimator.mid_blocks.12.transformer_blocks.0.ff.gelu_gate.proj.weight",
            "s3gen.mel2wav.resblocks.1.convs1.2.weight": "mel2wav.resblocks.1.convs1.2.conv.weight",
            "s3gen.mel2wav.f0_predictor.classifier.weight": "mel2wav.f0_predictor.classifier.weight",
        ]
        for (key, target) in cases { XCTAssertEqual(try AcousticInventory.route(key).target, target) }
    }
    func testAllCapturedLearnedWeightsMapToActualConstructorShapes() throws {
        struct Raw: Decodable { let raw: String; let dtype: String; let shape: [Int] }
        struct Constructor: Decodable { let key: String; let dtype: String; let shape: [Int] }
        struct Capture: Decodable {
            let report_sha256: String; let raw: [Raw]; let constructor: [Constructor]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "v03-actual-metadata", withExtension: "json", subdirectory: "Fixtures"))
        let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
        XCTAssertEqual(capture.report_sha256, "20ddc1347e30e10e7cc179b74550c31cf9686d3897dcdc77b5ea83af583bc83e")
        XCTAssertEqual(capture.raw.count, 2487)
        let constructor = Dictionary(uniqueKeysWithValues: capture.constructor.map { ($0.key, $0) })
        var targets: Set<String> = []
        for raw in capture.raw {
            guard let target = try AcousticInventory.route(raw.raw).target else { continue }
            XCTAssertTrue(targets.insert(target).inserted, "collision: \(target)")
            let actual = try XCTUnwrap(constructor[target], target)
            XCTAssertEqual(actual.shape, raw.shape, target)
            XCTAssertEqual(actual.dtype, "float32", target); XCTAssertEqual(raw.dtype, "F32", target)
        }
        XCTAssertEqual(targets.count, 1367)
        // This preserved capture is the REJECTED V03 graph, not a passing runtime
        // reference. V04 must physically remove its mixer and pass a fresh gate.
        XCTAssertEqual(Set(constructor.keys).subtracting(targets), [
            "decoder.estimator.time_embed_mixer.weight", "decoder.randNoise",
            "encoder.embed.pos_enc.pe", "encoder.up_embed.pos_enc.pe", "mel2wav.stftWindow"])
    }
    func testWrongRuntimeAssetFailsBeforeAnyMLXInitialization() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data([0]).write(to: path)
        XCTAssertThrowsError(try AcousticRuntimeAsset(url: path))
        try Data(repeating: 0, count: AcousticRuntimeAsset.bytes).write(to: path)
        XCTAssertThrowsError(try AcousticRuntimeAsset(url: path))
    }
    func testHeaderRejectsOverflowInvalidOffsetsAndPayloadSize() throws {
        try AcousticTensor(dtype: "F32", shape: [2, 3], data_offsets: [0, 24]).validate(payloadBytes: 24)
        for spec in [
            AcousticTensor(dtype: "F16", shape: [2, 3], data_offsets: [0, 12]),
            .init(dtype: "F32", shape: [Int.max, 2], data_offsets: [0, 24]),
            .init(dtype: "F32", shape: [2, 3], data_offsets: [-1, 23]),
            .init(dtype: "F32", shape: [2, 3], data_offsets: [0]),
            .init(dtype: "F32", shape: [2, 3], data_offsets: [0, 20]),
            .init(dtype: "F32", shape: [2, 0], data_offsets: [0, 0]),
        ] { XCTAssertThrowsError(try spec.validate(payloadBytes: 24)) }
    }
}
#endif
