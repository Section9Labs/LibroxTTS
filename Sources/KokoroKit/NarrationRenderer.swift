import PocketTTSMLX
import Foundation
import Darwin
import KokoroAudio
import KokoroNarration
import os
import LibroxCTNative
@_exported import KokoroNarration

/// Serial owner of the Basic Kokoro and Plus CT renderers. Legacy model selections
/// are rejected before loading; they never reinterpret a previous model receipt.
public actor NarrationRenderer {
    public enum ExecutionContext: Sendable { case foreground, background }
    // User playback rate controls the base pace. Delivery cues may still make
    // local expressive adjustments, but Spanish has no hidden global slowdown.
    public static let deliveryRevision = "profiled-narration-runtime-1"
    public enum RenderError: LocalizedError {
        case unavailable(String), invalidAudio, memory, thermal
        public var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .invalidAudio: "The selected voice produced invalid audio. Try preparing this chapter again."
            case .memory: "Listening paused because memory is low. Your place is saved; close other apps, then press Play."
            case .thermal: "Listening paused while your device cools down. Your place is saved; press Play in a few minutes."
            }
        }
    }
    private var pocket: PocketTTSEngine?
    private var plus: CTEngine?
    private var plusBackend: CTEngine.Backend?
    private var leased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var kokoro: KokoroEngine?
    private var current: NarrationModel?
    private var currentDirectory: URL?
    private var currentRepositoryID: String?
    private let compactDirectory: URL
    private let harmonicSource: URL?
    private let contextStyleDiagnostic: CTContextStyleDiagnostic.Configuration?
    private let logger = Logger(subsystem: "com.section9labs.Libros", category: "NarrationRenderer")

    /// Host-facing initializer: storage and bundled resources, with no model graph knowledge.
    public init(storageRoot: URL, resources: Bundle, expressionDirectory: URL? = nil) {
        compactDirectory = storageRoot.appendingPathComponent(
            NarrationAssets.repositoryID(.compact).replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        harmonicSource = resources.url(forResource: "NarrationSource", withExtension: "mlmodelc")
        contextStyleDiagnostic = expressionDirectory.map(CTApprovedExpression.configuration)
    }

    public init(compactDirectory: URL, harmonicSource: URL?,
                contextStyleDiagnostic: CTContextStyleDiagnostic.Configuration? = nil) {
        self.compactDirectory = compactDirectory
        self.harmonicSource = harmonicSource
        self.contextStyleDiagnostic = contextStyleDiagnostic
    }

    private func acquire() async {
        if leased { await withCheckedContinuation { waiters.append($0) } }
        else { leased = true }
    }
    private func release() {
        if waiters.isEmpty { leased = false } else { waiters.removeFirst().resume() }
    }
    public func unload() async {
        await acquire(); defer { release() }
        await unloadHeld()
    }
    private func unloadHeld() async {
        await pocket?.unload(); pocket = nil
        await plus?.unload(); plus = nil
        plusBackend = nil
        await kokoro?.unload()
        kokoro = nil
        current = nil; currentDirectory = nil; currentRepositoryID = nil
    }

    public func load(_ selection: NarrationModel, directory: URL,
                     executionContext: ExecutionContext = .background, repositoryID: String? = nil) async throws {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        guard selection.isEnabled else {
            throw RenderError.unavailable("Choose Basic, Plus or System voices in Listening settings.")
        }
        if selection == .pocket, executionContext == .background {
            throw RenderError.unavailable("Pocket TTS requires foreground GPU generation. Play prepared audio in the background.")
        }
        let backend: CTEngine.Backend = executionContext == .foreground ? .coreMLGPUHeavy : .coreMLCPU
        let directory = directory.standardizedFileURL
        let repositoryID = repositoryID ?? NarrationAssets.repositoryID(selection)
        guard NarrationAssets.compatibleRepositoryIDs(selection).contains(repositoryID) else {
            throw RenderError.unavailable("This installed voice version is not supported by the current library.")
        }
        if current == selection, currentDirectory == directory, currentRepositoryID == repositoryID {
            if selection == .plus, plusBackend != backend, let plus {
                do { try await plus.setBackend(backend); plusBackend = backend }
                catch { await unloadHeld(); throw error }
            }
            return
        }
        await unloadHeld()
        if selection == .pocket {
            pocket = PocketTTSEngine(directory: directory)
            current = selection; currentDirectory = directory; currentRepositoryID = repositoryID
            return
        }
        if selection == .plus {
            let engine = CTEngine(directory: directory, backend: backend, assetIdentity: repositoryID,
                contextStyleDiagnostic: contextStyleDiagnostic)
            try await engine.load()
            do { try Task.checkCancellation() } catch { await engine.unload(); throw error }
            plus = engine; plusBackend = backend; current = selection; currentDirectory = directory; currentRepositoryID = repositoryID
            return
        }
        let started = Date()
        let narration = harmonicSource.map {
            KokoroEngine.NarrationConfiguration(harmonicSource: $0,
                frontend: selection == .kokoroDesktop ? directory.appendingPathComponent("frontend-fp32.mlmodelc") : nil)
        }
        // Enhanced requires its own frontend; never silently play Basic under
        // the Enhanced label when the bundled narration source is unavailable.
        if selection == .kokoroDesktop, narration == nil {
            throw RenderError.unavailable("Basic listening isn’t included in this build. Choose Previous Basic or System voices.")
        }
        let engine = KokoroEngine(modelDirectory: compactDirectory, computePolicy: .cpuOnly,
            pronunciationPolicy: .independent,
            rendererPolicy: .fixedSize(directory: compactDirectory.appendingPathComponent("decoder")), narration: narration)
        try await engine.load()
        do { try Task.checkCancellation() }
        catch { await engine.unload(); throw error }
        kokoro = engine
        current = selection; currentDirectory = directory; currentRepositoryID = repositoryID
        logger.notice("Narration model load completed in \(Date().timeIntervalSince(started), privacy: .public) seconds")
    }

    public func render(_ unit: BookNarrationUnit, delivery: NarrationDeliveryOptions = .init()) async throws -> [Float] {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        if let pocket {
            let sampling = unit.pocketSampling ?? .init()
            try sampling.validate()
            return try await pocket.synthesize(unit.synthesisText, voiceID: unit.voiceID,
                temperature: sampling.temperature, chunking: unit.pocketChunking ?? .init(),
                role: unit.role == .dialogue ? .dialogue : .narration, samplerSteps: sampling.samplerSteps).samples
        }
        if let plus {
            guard let voice = NarrationModel.plus.nativeVoices.first(where: { $0.id == unit.voiceID }) else {
                throw CTError.unsupportedVoice
            }
            try await plus.setVoice(voice.engineVoiceID, blend: delivery.nativeBlend(for: unit.voiceID))
            return try await renderNative(unit.synthesisText, language: voice.language, engine: plus,
                                          textContext: delivery.nativeBlend(for: unit.voiceID) == nil ? unit.nativeTextContext : nil,
                                          expression: delivery.nativeBlend(for: unit.voiceID) == nil ? unit.nativeExpression : nil)
        }
        guard let kokoro else { throw RenderError.invalidAudio }
        let audio: Audio
        let profile = current?.deliveryProfile ?? .basic
        let speed = profile.speed(for: unit)
        if harmonicSource != nil, !unit.requiresRendererSplit {
            let gestures = profile.focus(for: unit).map {
                NarrationPitchGesture(phonemeRange: $0.phonemeRange, semitones: $0.semitones)
            }
            let blend = profile == .enhanced ? delivery.secondaryVoice(for: unit.voiceID) : nil
            audio = try await kokoro.synthesizeNarration(unit.phonemes, voiceID: unit.voiceID,
                styleRow: profile.styleRow(for: unit), speed: speed, pitchGestures: gestures,
                voiceBlend: blend.map { NarrationVoiceBlend(secondaryVoiceID: $0.id, weight: $0.weight) })
        } else {
            audio = try await kokoro.synthesize(unit.synthesisText, voiceID: unit.voiceID, speed: speed)
        }
        return try enhance(audio.samples)
    }

    private func renderNative(_ text: String, language: String, engine: CTEngine, depth: Int = 0,
                              textContext: CTTextContext.Binding? = nil,
                              expression: CTExpressionInput? = nil) async throws -> [Float] {
        try Task.checkCancellation()
        do {
            let native = try await engine.synthesize(text, language: language, completeSentence: false, textContext: textContext, expression: expression)
            try Task.checkCancellation()
            return try CTDelivery.prepare(native.samples, sampleRate: NarrationModel.plus.outputSampleRate,
                                           level: .nativeDynamics).samples
        } catch CTError.passageTooLong {
            // Duration is predicted from the actual language and voice, not a
            // universal character count. Retry bounded fragments only if needed.
            guard depth < 8, text.count > 8 else { throw CTError.passageTooLong }
            let midpoint = text.index(text.startIndex, offsetBy: text.count / 2)
            let prefix = text[..<midpoint]
            let boundary = prefix.lastIndex(where: { ",;:，、；：".contains($0) })
                ?? prefix.lastIndex(where: \.isWhitespace) ?? midpoint
            let split = boundary == text.startIndex ? midpoint : text.index(after: boundary)
            let first = try await renderNative(String(text[..<split]), language: language, engine: engine, depth: depth + 1)
            let second = try await renderNative(String(text[split...]), language: language, engine: engine, depth: depth + 1)
            return first + second
        }
    }

    public struct NativeDiagnostic: Sendable {
        public let samples: [Float]
        public let native: CTEngine.Output
    }

    /// Native-only review of one bounded unit with supplied noise. Uses the same
    /// model, voice and delivery as render(); does not silently split a comparison.
    public func renderNativeDiagnostic(_ unit: BookNarrationUnit, initialNoise: CTTensor? = nil,
                                       delivery: NarrationDeliveryOptions = .init(), captureTrace: Bool = true) async throws -> NativeDiagnostic {
        await acquire(); defer { release() }
        try Task.checkCancellation()
        guard let plus, let voice = NarrationModel.plus.nativeVoices.first(where: { $0.id == unit.voiceID }) else {
            throw RenderError.invalidAudio
        }
        let blend = delivery.nativeBlend(for: unit.voiceID)
        try await plus.setVoice(voice.engineVoiceID, blend: blend)
        let native = try await plus.synthesize(unit.synthesisText, language: voice.language,
            initialNoise: initialNoise, captureTrace: captureTrace, completeSentence: false,
            textContext: blend == nil ? unit.nativeTextContext : nil,
            expression: blend == nil ? unit.nativeExpression : nil)
        let prepared = try CTDelivery.prepare(native.samples, sampleRate: NarrationModel.plus.outputSampleRate,
                                             level: .nativeDynamics)
        return NativeDiagnostic(samples: prepared.samples, native: native)
    }

    private func enhance(_ samples: [Float]) throws -> [Float] {
        // Match the listening comparisons: balanced resonance reduction on the
        // compact/HD renderer, never pitch correction or lossy audio encoding.
        // Complete units are latency aligned before they enter the playback queue.
        let filter = try VoiceEnhancer(preset: .balanced)
        var input = [Float](repeating: 0, count: 256)
        var output = input
        var result: [Float] = []; result.reserveCapacity(samples.count)
        let blocks = (samples.count + 255) / 256 + 3
        for block in 0..<blocks {
            try Task.checkCancellation()
            for index in input.indices {
                let position = block * 256 + index
                input[index] = position < samples.count ? samples[position] : 0
            }
            try filter.process(input, into: &output)
            let first = max(0, 768 - block * 256)
            let end = min(256, 768 + samples.count - block * 256)
            if first < end { result.append(contentsOf: output[first..<end]) }
        }
        guard result.count == samples.count,
              result.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw RenderError.invalidAudio }
        return result
    }

    public static var canPrewarm: Bool { canPrewarm(.kokoroDesktop) }

    public static func canPrewarm(_ selection: NarrationModel) -> Bool {
        guard ProcessInfo.processInfo.thermalState == .nominal else { return false }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        // Speculative CT startup measured roughly 2 GiB peak RSS on the phone.
        // Leave additional headroom for the reader and foreground applications.
        let requiredMiB: UInt64 = selection == .plus ? 2_560 : 512
        return os_proc_available_memory() > requiredMiB * 1_048_576
        #else
        return true
        #endif
    }
}
