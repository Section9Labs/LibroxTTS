// SPDX-License-Identifier: Apache-2.0 OR MIT
import Foundation
import KokoroCatalog
import KokoroPronunciation

/// Versioned delivery configuration shared by app playback and listening probes.
/// Model assets and audio-session ownership remain with the host application.
public enum NarrationProfile: String, Codable, Sendable, CaseIterable {
    case basic, enhanced

    public var targetPhonemes: Int { self == .enhanced ? 180 : 320 }
    public var prosody: BookNarrationProsody { self == .enhanced ? .structuredConversation : .baseline }
    public var cacheRevision: String {
        switch self {
        case .basic: "basic-runtime-1:style158:balanced:" + NarrationDelivery.revision
        case .enhanced: "enhanced-runtime-1:length:balanced:" + EnhancedNarrationDelivery.revision
            + ":" + BoundedNarrationContext.revision + ":" + ConversationCadence.revision + ":" + DialogueTiming.revision
        }
    }
    public func prepare(_ units: [BookNarrationUnit]) -> [BookNarrationUnit] {
        self == .enhanced ? BoundedNarrationContext.prepare(units) : units
    }
    public func styleRow(for unit: BookNarrationUnit) -> Int {
        self == .enhanced ? NarrationStylePolicy.length.row(phonemeCount: unit.phonemes.unicodeScalars.count) : 158
    }
    public func focus(for unit: BookNarrationUnit) -> [NarrationFocus] {
        self == .enhanced ? Array((EnhancedNarrationDelivery.focus(for: unit) + unit.expressiveFocus).prefix(16)) : []
    }
    public func speed(for unit: BookNarrationUnit) -> Float {
        self == .enhanced ? 1 : unit.expression.speedMultiplier
    }
    /// Add model/frontend identity, pronunciation revision, voice and phones in
    /// the host cache key. Include resolved focus: role can change the rendering
    /// even when a source phrase and its pronunciation are identical.
    public func renderIdentity(for unit: BookNarrationUnit) -> String {
        let gestures = focus(for: unit).map { "\($0.phonemeRange.lowerBound)-\($0.phonemeRange.upperBound):\($0.semitones)" }.joined(separator: ",")
        return "\(cacheRevision):row\(styleRow(for: unit)):speed\(speed(for: unit)):focus[\(gestures)]"
    }
}

/// Preserve small utterances' real written context without borrowing another
/// character's voice or inventing carrier text. Language-agnostic grouping never
/// adds English intonation to other languages. Uncertain speaker turns abstain.
public enum BoundedNarrationContext {
    public static let revision = "bounded-narration-context-1"
    public static let maximumPhonemes = 180
    public static func prepare(_ units: [BookNarrationUnit]) -> [BookNarrationUnit] {
        var result: [BookNarrationUnit] = []
        result.reserveCapacity(units.count)
        func short(_ unit: BookNarrationUnit) -> Bool { (1..<20).contains(unit.phonemes.unicodeScalars.count) }
        func compatible(_ left: BookNarrationUnit, _ right: BookNarrationUnit) -> Bool {
            left.voiceID == right.voiceID && NSMaxRange(left.range) == right.range.location
                && left.phonemes.unicodeScalars.count + right.phonemes.unicodeScalars.count <= maximumPhonemes
        }
        func combine(_ left: BookNarrationUnit, _ right: BookNarrationUnit) -> BookNarrationUnit {
            var merged = BookNarrationUnit(text: left.text + right.text,
                range: .init(location: left.range.location, length: left.range.length + right.range.length),
                voiceID: right.voiceID, phonemes: left.phonemes + right.phonemes, boundaryAfter: right.boundaryAfter)
            // The exit identity/role controls the following acoustic boundary.
            merged.role = right.role; merged.speakerID = right.speakerID
            merged.pronunciationDiagnostics = left.pronunciationDiagnostics + right.pronunciationDiagnostics
            return merged
        }
        for unit in units {
            guard let prior = result.last, compatible(prior, unit) else { result.append(unit); continue }
            if short(unit), unit.role == .dialogue, prior.role == .attribution,
               prior.speakerID == nil || prior.speakerID == unit.speakerID {
                var merged = combine(result.removeLast(), unit)
                // Accepted Spanish stage-dialogue case; safe to use in other
                // languages when the planner supplies the same explicit roles.
                if let context = result.last, context.role == .narration, compatible(context, merged) {
                    merged = combine(result.removeLast(), merged)
                }
                result.append(merged)
            } else if (short(unit) || short(prior)), prior.boundaryAfter != .paragraph,
                      !prior.phonemes.isEmpty, !unit.phonemes.isEmpty,
                      (prior.role == .narration && unit.role == .narration
                       || prior.role == .dialogue && unit.role == .dialogue
                          && prior.speakerID != nil && prior.speakerID == unit.speakerID) {
                // Preserve a small fragment in the same known turn/paragraph.
                result.append(combine(result.removeLast(), unit))
            } else { result.append(unit) }
        }
        return result
    }
}

/// Constant-sized seam state. Cached audio stays unpaced, so resume and chapter
/// transitions use current context rather than replaying previously added gaps.
public struct NarrationPlaybackCadence: Sendable {
    private let profile: NarrationProfile
    private var basic = NarrationCadence(pacing: .audiobook)
    private var conversation = ConversationCadence()
    private struct Edge: Sendable {
        let text: String
        let speaker: String?
        let role: DialogueTimingRole
        let boundary: NarrationBoundary
    }
    private var previous: Edge?
    public init(profile: NarrationProfile) { self.profile = profile }

    @discardableResult
    public mutating func apply(to samples: inout [Float], unit: BookNarrationUnit,
                               sampleRate: Int = 24_000, chapterBreak: Bool = false,
                               sourceGap: String = "") -> Int {
        guard profile == .enhanced else {
            return basic.apply(to: &samples, boundaryAfter: unit.boundaryAfter,
                voiceID: unit.voiceID, sampleRate: sampleRate, chapterBreak: chapterBreak)
        }
        let result = conversation.apply(to: &samples, context: .init(previousText: previous?.text ?? "", nextText: unit.text,
            previousSpeakerID: previous?.speaker, nextSpeakerID: unit.speakerID,
            previousRole: previous?.role ?? .unknown, nextRole: unit.role,
            structuralBreak: chapterBreak ? .chapter : previous?.boundary == .paragraph ? .paragraph : .none,
            sourceGap: sourceGap, languageCode: Voice.named(unit.voiceID)?.language.rawValue), sampleRate: sampleRate)
        if result.accepted {
            previous = Edge(text: String(String.UnicodeScalarView(unit.text.unicodeScalars.suffix(256))),
                speaker: unit.speakerID, role: unit.role, boundary: unit.boundaryAfter)
        } else { previous = nil }
        return result.insertedSamples
    }
}
