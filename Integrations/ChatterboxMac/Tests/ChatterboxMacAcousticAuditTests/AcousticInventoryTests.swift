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
