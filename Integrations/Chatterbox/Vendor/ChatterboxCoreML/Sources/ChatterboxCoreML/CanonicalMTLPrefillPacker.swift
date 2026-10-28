import Foundation

/// Official regular multilingual T3 inference layout. Conditioning construction
/// is separate; this function packs supplied FP32 rows without Core ML or MLX.
enum CanonicalMTLPrefillPacker {
    struct Packed {
        let inputsEmbeds: [Float]
        let positionIds: [Int32]
        let logitsSelectMask: [Float]
        let realLength: Int
    }

    static func pack(conditioning: [Float], lexicalText: [Float], textPositions: [Float],
                     bos: [Float], window: Int, hidden: Int, useCFG: Bool) -> Packed {
        precondition(hidden > 0 && conditioning.count % hidden == 0)
        precondition(lexicalText.count % hidden == 0 && textPositions.count == lexicalText.count)
        precondition(bos.count == hidden)
        let condRows = conditioning.count / hidden
        let textRows = lexicalText.count / hidden
        let real = condRows + textRows + 2
        precondition(real <= window)
        let stride = window * hidden
        var values = [Float](repeating: 0, count: 2 * stride)
        for lane in 0..<2 {
            let base = lane * stride
            for i in conditioning.indices { values[base + i] = conditioning[i] }
            for i in lexicalText.indices {
                // Official zero_() affects lexical rows BEFORE positions are added.
                let lexical: Float = lane == 1 && useCFG ? 0 : lexicalText[i]
                values[base + conditioning.count + i] = lexical + textPositions[i]
            }
            for row in 0..<2 {
                let start = base + (condRows + textRows + row) * hidden
                for i in 0..<hidden { values[start + i] = bos[i] }
            }
        }
        var positions = [Int32](repeating: 0, count: window)
        var select = [Float](repeating: 0, count: window)
        for i in 0..<real { positions[i] = Int32(i) }
        select[real - 1] = 1
        return Packed(inputsEmbeds: values, positionIds: positions,
                      logitsSelectMask: select, realLength: real)
    }
}
