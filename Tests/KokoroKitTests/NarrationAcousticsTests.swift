// SPDX-License-Identifier: Apache-2.0 OR MIT
import Testing
import Foundation
@testable import LibroxTTS

@Test func localPitchPreservesUnvoicedAndOutsideTarget() throws {
    let pitch: [Float] = Array(repeating: 140, count: 16) + [0, 0] + Array(repeating: 140, count: 14)
    let gesture = NarrationPitchGesture(phonemeRange: 1..<2, semitones: 1)
    let result = try NarrationAcoustics.adjusted(pitch, durations: [4,4,4,4], phonemeCount: 2, gestures: [gesture])
    #expect(Array(result.prefix(16)) == Array(pitch.prefix(16)))
    #expect(Array(result.suffix(8)) == Array(pitch.suffix(8)))
    #expect(result[16] == 0 && result[17] == 0 && result[20] > pitch[20])
    #expect(try NarrationAcoustics.adjusted(pitch, durations: [], phonemeCount: 2, gestures: []) == pitch)
}

@Test func overlappingLocalGesturesStayBoundedAndKeepDurations() throws {
    let pitch = [Float](repeating: 200, count: 48)
    let gestures = [NarrationPitchGesture](repeating: .init(phonemeRange: 0..<2, semitones: 1.5), count: 8)
    let result = try NarrationAcoustics.adjusted(pitch, durations: [4,8,8,4], phonemeCount: 2, gestures: gestures)
    #expect(result.count == pitch.count)
    #expect(result.prefix(8).elementsEqual(pitch.prefix(8)))
    #expect(result.suffix(8).elementsEqual(pitch.suffix(8)))
    #expect(zip(result, pitch).allSatisfy { abs(12 * log2($0 / $1)) <= 1.501 })
}

@Test func localPitchRejectsInvalidAlignmentAndBounds() throws {
    let pitch: [Float] = Array(repeating: 140, count: 32)
    for gesture in [NarrationPitchGesture(phonemeRange: 0..<3, semitones: 1),
                    .init(phonemeRange: 0..<1, semitones: .nan),
                    .init(phonemeRange: 0..<1, semitones: 3)] {
        #expect(throws: SynthesisError.self) {
            try NarrationAcoustics.adjusted(pitch, durations: [4,4,4,4], phonemeCount: 2, gestures: [gesture])
        }
    }
    #expect(throws: SynthesisError.self) {
        try NarrationAcoustics.adjusted(pitch, durations: [4,4,4], phonemeCount: 2,
            gestures: [.init(phonemeRange: 0..<1, semitones: 1)])
    }
}
