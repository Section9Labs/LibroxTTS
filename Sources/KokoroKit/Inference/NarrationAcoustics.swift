// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import CoreML

/// An opt-in acoustic hypothesis, not a trained emotion. Offsets are Unicode
/// scalar indices in the exact phoneme string passed to synthesis, excluding BOS.
/// A raised-cosine gesture changes voiced pitch locally; durations stay intact.
public struct NarrationPitchGesture: Sendable, Equatable {
    public let phonemeRange: Range<Int>
    public let semitones: Float
    public init(phonemeRange: Range<Int>, semitones: Float) {
        self.phonemeRange = phonemeRange; self.semitones = semitones
    }
}

/// Blend a second same-language reference, never a second synthesis model.
/// Weight is the secondary voice's share; callers must include it in cache keys.
public struct NarrationVoiceBlend: Sendable, Equatable {
    public let secondaryVoiceID: String
    public let weight: Float
    public init(secondaryVoiceID: String, weight: Float) {
        self.secondaryVoiceID = secondaryVoiceID; self.weight = weight
    }
}

enum NarrationAcoustics {
    static func adjusted(_ pitch: [Float], durations: [Int], phonemeCount: Int,
                         gestures: [NarrationPitchGesture]) throws -> [Float] {
        guard !gestures.isEmpty else { return pitch }
        guard (1...510).contains(phonemeCount), gestures.count <= 16,
              durations.count == phonemeCount + 2,
              durations.allSatisfy({ (0...4096).contains($0) }),
              durations.reduce(0, +) * 2 == pitch.count, pitch.count <= 8192,
              pitch.allSatisfy(\.isFinite),
              gestures.allSatisfy({ !$0.phonemeRange.isEmpty && $0.phonemeRange.lowerBound >= 0
                  && $0.phonemeRange.upperBound <= phonemeCount && $0.semitones.isFinite
                  && abs($0.semitones) <= 1.5 }) else { throw SynthesisError.invalidAudio }
        var boundaries = [0]
        for duration in durations { boundaries.append(boundaries.last! + duration * 2) }
        var shifts = [Float](repeating: 0, count: pitch.count)
        for gesture in gestures {
            let start = boundaries[gesture.phonemeRange.lowerBound + 1]
            let end = boundaries[gesture.phonemeRange.upperBound + 1]
            guard end - start >= 8 else { continue }
            for i in start..<end {
                let phase = Double(i - start) / Double(end - start - 1)
                shifts[i] += gesture.semitones * Float(0.5 - 0.5 * cos(2 * .pi * phase))
            }
        }
        return zip(pitch, shifts).map { value, shift in
            guard (40...600).contains(value), shift != 0 else { return value }
            let bounded = min(1.5, max(-1.5, shift))
            return min(600, max(40, value * pow(2, bounded / 12)))
        }
    }

    static func adjusted(_ pitch: MLMultiArray, durations: MLMultiArray,
                         phonemeCount: Int, gestures: [NarrationPitchGesture]) throws -> MLMultiArray {
        guard !gestures.isEmpty else { return pitch }
        guard pitch.shape.count == 2, pitch.shape[0].intValue == 1,
              durations.count == phonemeCount + 2, pitch.count <= 8192 else { throw SynthesisError.invalidAudio }
        let values = try adjusted((0..<pitch.count).map { pitch[$0].floatValue },
            durations: (0..<durations.count).map { durations[$0].intValue },
            phonemeCount: phonemeCount, gestures: gestures)
        let output = try MLMultiArray(shape: pitch.shape, dataType: .float32)
        for i in values.indices { output[i] = NSNumber(value: values[i]) }
        return output
    }
}
