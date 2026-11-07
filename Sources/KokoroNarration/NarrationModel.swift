import Foundation
import KokoroCatalog
import LibroxCTNative

/// Stable, persisted selection. Eligibility never rewrites a user's choice.
public enum NarrationModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case compact, enhanced, kokoroDesktop, qwenDesktop
    case plus = "ctPlusV1"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .compact: "Previous Basic"
        case .enhanced: "Previous Enhanced"
        case .kokoroDesktop: "Basic"
        case .plus: "Plus"
        case .qwenDesktop: "Previous Studio"
        }
    }
    public var isQwen: Bool { self == .enhanced || self == .qwenDesktop }
    /// Retain legacy raw values for receipts and caches; never reinterpret Qwen
    /// audio as Kokoro when the user-facing quality names change.
    public var isEnabled: Bool { !isQwen }
    public var deliveryProfile: NarrationProfile { self == .kokoroDesktop ? .enhanced : .basic }
    public var supportedSelection: Self { isEnabled ? self : .compact }
    public var usesTextNativePlanning: Bool { self == .plus }
    public var supportsCharacterVoices: Bool { self == .compact || self == .kokoroDesktop || self == .plus }
    public var supportsExpressiveDelivery: Bool { self == .compact || self == .kokoroDesktop }
    public var supportsVoiceBlending: Bool { self == .kokoroDesktop || self == .plus }
    public var supportsPronunciationDialect: Bool { self == .compact || self == .kokoroDesktop }
    /// Unsupported saved controls remain saved by the host, but must not create
    /// a different preparation/cache request for identical native audio.
    public func resolvedDeliveryOptions(_ options: NarrationDeliveryOptions) -> NarrationDeliveryOptions {
        .init(expressive: supportsExpressiveDelivery && options.expressive,
              blendedVoice: supportsVoiceBlending && options.blendedVoice)
    }
    public var requiresPlusAccess: Bool { self == .plus }
    public var usesPreparedCache: Bool { self == .kokoroDesktop || self == .plus }
    public var dependencies: [Self] { self == .kokoroDesktop ? [.compact] : [] }
    public var outputSampleRate: Int { nativeSampleRate }
    public var nativeSampleRate: Int { self == .plus ? 44_100 : 24_000 }
    public var deliveryIdentity: String {
        self == .plus ? "dk-delivery-v1:native44100:source-boundaries:native-dynamics" : "profiled-narration-runtime-1"
    }
    public func renderIdentity(for unit: BookNarrationUnit) -> String {
        self == .plus ? deliveryIdentity + ":context="
            + (unit.nativeExpression?.cacheIdentity ?? unit.nativeTextContext?.renderCacheKey ?? "none")
            : deliveryProfile.renderIdentity(for: unit)
    }
    public struct NativeVoice: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let language: String
        public let styleID: String
        public var engineVoiceID: String { "dk-" + styleID.lowercased() + "-v1" }
    }
    public var nativeVoices: [NativeVoice] {
        self == .plus ? CTAssets.styles.flatMap { style in
            supportedLanguageCodes.map { language in
                NativeVoice(id: "plus-\(style.lowercased())-\(language)-v1",
                    name: style + " · " + NarrationLanguage.name(language), language: language, styleID: style)
            }
        } : []
    }
    public var supportedLanguageCodes: [String] {
        self == .plus ? NarrationLanguage.textNativeCodes : Language.allCases.map(\.rawValue)
    }
    public func resolvedVoiceID(_ preferred: String?, language: String) -> String? {
        guard let language = NarrationLanguage.normalize(language), supportedLanguageCodes.contains(language) else { return nil }
        if self == .plus {
            let style = nativeVoices.first { $0.id == preferred }?.styleID ?? "F1"
            return nativeVoices.first { $0.language == language && $0.styleID == style }?.id
        }
        if let preferred, let voice = Voice.named(preferred), voice.language.rawValue == language { return preferred }
        return Language(rawValue: language).map { Voice.preferred(for: $0).id }
    }
    public var requiresPreparation: Bool { self == .qwenDesktop }
    public var detail: String {
        switch self {
        case .compact: "Small download · Listen immediately"
        case .enhanced: "Richer narration · On-device listening"
        case .kokoroDesktop: "On-device listening"
        case .plus: "10 voices · 31 languages"
        case .qwenDesktop: "Expressive narration · Prepare chapters before listening"
        }
    }

    public struct Device: Sendable {
        public let appleSilicon: Bool
        public let desktop: Bool
        public let physicalMemory: UInt64
        public let identifier: String
        public init(appleSilicon: Bool, desktop: Bool, physicalMemory: UInt64, identifier: String) {
            self.appleSilicon = appleSilicon; self.desktop = desktop
            self.physicalMemory = physicalMemory; self.identifier = identifier
        }
    }
    /// Development qualification, not a promise based on chip generation alone.
    /// Expand phone/tablet eligibility only after real-app memory/lifecycle trials.
    public static func available(on device: Device) -> [Self] {
        allCases.filter { $0.unavailableReason(on: device) == nil }
    }
    public func unavailableReason(on device: Device) -> String? {
        guard device.appleSilicon else { return "These voices require Apple silicon." }
        guard isEnabled else {
            return "These earlier voices are temporarily unavailable. Choose Basic, Plus or System voices in Listening settings."
        }
        switch self {
        case .compact: return nil
        case .plus:
            let testedPhone = device.identifier == "iPhone18,2" && device.physicalMemory >= 12_000_000_000
            let testedTablet = device.identifier == "iPad16,3" && device.physicalMemory >= 7_500_000_000
            guard !device.desktop, testedPhone || testedTablet else {
                return "Plus is currently supported on the tested iPhone 17 Pro Max and iPad Pro M4 configurations. Other devices are not qualified yet."
            }
            return nil
        case .kokoroDesktop:
            if device.desktop { return nil }
            guard device.identifier == "iPhone18,2", device.physicalMemory >= 12_000_000_000 else {
                return "Basic has not yet been tested on this device. Previous Basic and System voices remain available."
            }
            return nil
        case .enhanced, .qwenDesktop:
            return "These earlier voices are temporarily unavailable."
        }
    }
}
