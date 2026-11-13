import Foundation
import KokoroCatalog

/// Default Max book-delivery calibration. Raw Pocket engine APIs remain unchanged.
/// Gains are frozen per published voice/language/reference style, never estimated
/// from the current sentence. No lookahead, state, silence removal or timing change.
package enum PocketNarrationLevel {
    package static var revision: String { PocketNarrationLevelProfiles.revision }

    package static func gain(voiceID: String, style: PocketTTSDeliveryStyle) -> Float {
        PocketNarrationLevelProfiles.gains[voiceID + "|" + style.rawValue] ?? 1
    }

    package static func apply(_ samples: consuming [Float], gain: Float) -> [Float] {
        guard gain != 1 else { return samples }
        // Normal speech receives one constant multiply, preserving its dynamics.
        // A boost may meet an unforeseen transient outside the calibration set.
        // A continuous soft knee prevents new sample clipping in that case only;
        // attenuation and unity never introduce a limiter or noise-floor boost.
        var output = samples
        let knee = PocketNarrationLevelProfiles.softKnee
        let width = PocketNarrationLevelProfiles.softKneeWidth
        for index in output.indices {
            let value = output[index] * gain
            if gain > 1, abs(value) > Float(knee) {
                let magnitude = knee + width * (1 - exp(-(Double(abs(value)) - knee) / width))
                output[index] = (value < 0 ? -1 : 1) * Float(magnitude)
            } else {
                output[index] = value
            }
        }
        return output
    }
}
