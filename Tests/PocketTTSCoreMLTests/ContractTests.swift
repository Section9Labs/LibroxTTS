import XCTest
import CoreML
import MLX
import PocketTTSMLX
@testable import PocketTTSCoreML

final class ContractTests: XCTestCase {
    func testStridedCoreMLOutputPreservesLogicalOrder() throws {
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        memory.initialize(from: [1,2,99,99,3,4,99,99], count: 8)
        let array = try MLMultiArray(dataPointer: memory, shape: [2,2], dataType: .float32, strides: [4,1], deallocator: { $0.assumingMemoryBound(to: Float.self).deallocate() })
        XCTAssertEqual(PocketTTSCoreMLEngine.values(array), [1,2,3,4])
    }
    func testMalformedTensorShapeFails() {
        XCTAssertThrowsError(try PocketTTSCoreMLEngine.floats([1,2], shape: [1,3]))
    }
    func testRealMLXStageParity() throws {
        guard let assets = ProcessInfo.processInfo.environment["POCKET_ASSETS"],
              let models = ProcessInfo.processInfo.environment["POCKET_COREML"] else { throw XCTSkip("Real model assets required") }
        try Device.withDefaultDevice(.cpu) {
            let root = URL(fileURLWithPath: assets).appendingPathComponent("en")
            let m = try PocketTTSModel.fromModelDirectory(root)
            let state = try m.loadVoiceState("caro_davy__calm")
            let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
            let modelRoot = URL(fileURLWithPath: models).appendingPathComponent("en")
            let text = try MLModel(contentsOf: modelRoot.appendingPathComponent("text.mlmodelc"), configuration: cfg)
            let latent = try MLModel(contentsOf: modelRoot.appendingPathComponent("latent.mlmodelc"), configuration: cfg)
            let flow = try MLModel(contentsOf: modelRoot.appendingPathComponent("flow4.mlmodelc"), configuration: cfg)
            func error(_ a: [Float], _ b: [Float]) -> Float { zip(a,b).map { abs($0-$1) }.max() ?? 0 }
            var caches: [String: Any] = [:]
            for (i,c) in state.flowCache.enumerated() {
                for j in 0..<2 { caches["cache\(2*i+j)"] = try PocketTTSCoreMLEngine.floats(c.state[j].asArray(Float.self), shape: c.state[j].shape) }
            }
            let prepared = try PocketTTSTextUtils.prepareTextPrompt("She rested her hand against the door. For a moment, she could almost hear his voice again.", config: m.config).0
            let tokens = m.flow_lm.conditioner.prepare(prepared)
            caches["value"] = try PocketTTSCoreMLEngine.ints(tokens.tokens.asArray(Int32.self).map(Int.init))
            caches["position"] = try PocketTTSCoreMLEngine.floats([Float(state.flowCache[0].offset)],shape:[1])
            let conditioned = try text.prediction(from: MLDictionaryFeatureProvider(dictionary: caches))
            _ = m.flow_lm.transformer(m.flow_lm.conditioner(tokens), cache: state.flowCache)
            eval(state.flowCache.flatMap(\.state))
            for i in 0..<12 {
                let a = try PocketTTSCoreMLEngine.output(conditioned, "next\(i)")
                let e = error(PocketTTSCoreMLEngine.values(a),state.flowCache[i/2].state[i%2].asArray(Float.self))
                print("prefill cache \(i) error \(e)")
                XCTAssertLessThan(e, 0.0003)
                caches["cache\(i)"] = a
            }
            var input = m.flow_lm.bos_emb.reshaped([1,1,32])
            for frame in 0..<12 {
                let (expected,eos) = m.flow_lm(sequence: input, textEmbeddings: MLXArray.zeros([1,0,1024]), cache: state.flowCache,
                    lsdDecodeSteps: 4, temperature: 0, noiseClamp: nil, eosThreshold: -4)
                eval(expected,eos)
                caches["value"] = try PocketTTSCoreMLEngine.floats(input.asArray(Float.self), shape: [1,1,32])
                caches["position"] = try PocketTTSCoreMLEngine.floats([Float((caches["cache0"] as! MLMultiArray).shape[2].intValue)],shape:[1])
                let hidden = try latent.prediction(from: MLDictionaryFeatureProvider(dictionary: caches))
                let predicted = try flow.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "condition": PocketTTSCoreMLEngine.floats(PocketTTSCoreMLEngine.values(PocketTTSCoreMLEngine.output(hidden,"hidden")), shape: [1,1024]),
                    "noise": PocketTTSCoreMLEngine.floats([Float](repeating: 0,count: 32),shape:[1,32])]))
                print("cache shapes frame \(frame): in \((caches["cache0"] as! MLMultiArray).shape) out \(try PocketTTSCoreMLEngine.output(hidden,"next0").shape) mlx \(state.flowCache[0].state[0].shape)")
                let got = try PocketTTSCoreMLEngine.values(PocketTTSCoreMLEngine.output(predicted,"latent"))
                let e = error(got,expected.asArray(Float.self))
                print("frame \(frame) latent error \(e), coreml \(got.prefix(4)), mlx \(expected.asArray(Float.self).prefix(4))")
                XCTAssertLessThan(e,0.001)
                for i in 0..<12 {
                    let a = try PocketTTSCoreMLEngine.output(hidden,"next\(i)")
                    caches["cache\(i)"] = try PocketTTSCoreMLEngine.floats(PocketTTSCoreMLEngine.values(a), shape:a.shape.map(\.intValue))
                }
                input = expected.reshaped([1,1,32])
            }
        }
    }
}
