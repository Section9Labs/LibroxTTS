import Foundation
import Testing
@testable import LibroxCTNative

@Test func nativeStyleBlendBoundsEndpointsAndTensorContract() throws {
    let primary = try CTTensor([Float(1), 3], shape: [1, 2])
    let secondary = try CTTensor([Float(5), 7], shape: [1, 2])
    let mix = CTVoiceBlend(secondaryVoiceID: "dk-f2-v1", weight: 0.25)
    #expect(try mix.interpolate(primary, secondary).floats() == [2, 4])
    #expect(try CTVoiceBlend(secondaryVoiceID: "dk-f2-v1", weight: 0).interpolate(primary, secondary).data == primary.data)
    #expect(try CTVoiceBlend(secondaryVoiceID: "dk-f2-v1", weight: 1).interpolate(primary, secondary).data == secondary.data)
    #expect(try CTVoiceBlend(secondaryVoiceID: "dk-f1-v1", weight: 0.4).validated(primaryVoiceID: "dk-f1-v1") == nil)
    for weight in [Float.nan, .infinity, -0.1, 1.1] {
        #expect(throws: CTError.self) { try CTVoiceBlend(secondaryVoiceID: "dk-f2-v1", weight: weight).validated(primaryVoiceID: "dk-f1-v1") }
    }
    #expect(throws: CTError.self) { try CTVoiceBlend(secondaryVoiceID: "af_heart", weight: 0.2).validated(primaryVoiceID: "dk-f1-v1") }
    #expect(throws: CTError.self) { try mix.interpolate(primary, CTTensor([Float(1)], shape: [1])) }
}
