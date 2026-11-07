import CoreML
import Foundation

/// The pinned vocoder unpacks each latent position into six decoder frames.
/// Its temporal convolutions span at most 117 frames (less than 20 latent
/// positions); normalization is per frame. Retaining 24 positions on either
/// side therefore preserves every dependency of the emitted centre samples.
/// No crossfade, resampling, padding, or text/context split is introduced.
enum CTVocoderWindows {
    static let samplesPerLatent = 3_072
    static let coreLength = 64
    static let context = 24
    static let maximumInputLength = coreLength + 2 * context

    struct Window: Equatable {
        let input: Range<Int>
        let output: Range<Int>
        var crop: Range<Int> {
            let start = (output.lowerBound - input.lowerBound) * samplesPerLatent
            let end = (output.upperBound - input.lowerBound) * samplesPerLatent
            return start..<end
        }
    }

    static func plan(length: Int) throws -> [Window] {
        guard (1...431).contains(length) else { throw CTError.passageTooLong }
        if length <= maximumInputLength { return [Window(input: 0..<length, output: 0..<length)] }
        return stride(from: 0, to: length, by: coreLength).map { start in
            let end = min(length, start + coreLength)
            return Window(input: max(0, start - context)..<min(length, end + context), output: start..<end)
        }
    }

    static func slice(_ feature: MLFeatureValue, range: Range<Int>) throws -> MLFeatureValue {
        guard let source = feature.multiArrayValue, source.dataType == .float32,
              source.shape.count == 3, source.shape[0].intValue == 1,
              source.shape[1].intValue == 144, !range.isEmpty,
              range.lowerBound >= 0, range.upperBound <= source.shape[2].intValue else {
            throw CTError.invalidTensor("vocoder window")
        }
        if range == 0..<source.shape[2].intValue { return feature }
        let target = try MLMultiArray(shape: [1, 144, NSNumber(value: range.count)], dataType: .float32)
        let input = source.dataPointer.assumingMemoryBound(to: Float.self)
        let output = target.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = source.strides[1].intValue, columnStride = source.strides[2].intValue
        for row in 0..<144 {
            if columnStride == 1 {
                output.advanced(by: row * range.count).update(
                    from: input.advanced(by: row * rowStride + range.lowerBound), count: range.count)
            } else {
                for (column, index) in range.enumerated() {
                    output[row * range.count + column] = input[row * rowStride + index * columnStride]
                }
            }
        }
        return MLFeatureValue(multiArray: target)
    }

    static func render(_ latent: MLFeatureValue,
                       predict: (MLFeatureValue) throws -> MLFeatureValue) throws -> [Float] {
        guard let length = latent.multiArrayValue?.shape.last?.intValue else {
            throw CTError.invalidTensor("vocoder latent")
        }
        var samples: [Float] = []
        samples.reserveCapacity(length * samplesPerLatent)
        for window in try plan(length: length) {
            try Task.checkCancellation()
            let centre: [Float] = try autoreleasepool {
                let audio = try CTCoreMLGraph.tensor(predict(slice(latent, range: window.input))).floats()
                guard audio.count == window.input.count * samplesPerLatent else { throw CTError.invalidAudio }
                return Array(audio[window.crop])
            }
            samples.append(contentsOf: centre)
        }
        return samples
    }
}
