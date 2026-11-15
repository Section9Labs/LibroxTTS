import Foundation
import KokoroNarration
import PocketTTSCoreML
import PocketTTSMLX

/// Internal engine seam: production retains the existing actor APIs, while
/// lifecycle tests can suspend and fail rendering without loading model assets.
protocol NarrationMaxBackend: Sendable {
    var isCoreML: Bool { get }
    var loadedLanguage: String? { get async }
    func unload() async
    func setContext(_ context: NarrationRenderer.ExecutionContext, cpuBudget: Double?) async
    func setBudget(_ fraction: Double?, context: NarrationRenderer.ExecutionContext) async
    func setObserver(_ observer: (@Sendable (PocketTTSResourceSnapshot) -> Void)?) async
    func synthesize(_ unit: BookNarrationUnit) async throws -> [Float]
    func renderFrames(_ unit: BookNarrationUnit,
                      onTextChunk: @Sendable (PocketTTSChunkProgress) throws -> Void,
                      receive: @Sendable ([Float]) throws -> Void) async throws
}

enum PocketNarrationBackend: NarrationMaxBackend {
    case coreML(PocketTTSCoreMLEngine)
    case mlx(PocketTTSEngine)

    static func make(directory: URL, context: NarrationRenderer.ExecutionContext) -> Self {
        if PocketTTSBackend.platform == .coreML {
            return .coreML(PocketTTSCoreMLEngine(directory: directory, placement: .cpu))
        }
        return .mlx(PocketTTSEngine(directory: directory, backend: context == .background ? .cpu : .gpu))
    }
    var isCoreML: Bool { if case .coreML = self { true } else { false } }
    var loadedLanguage: String? {
        get async {
            switch self {
            case .coreML(let engine): await engine.loadedLanguage
            case .mlx(let engine): await engine.loadedLanguage
            }
        }
    }
    func unload() async {
        switch self { case .coreML(let engine): await engine.unload(); case .mlx(let engine): await engine.unload() }
    }
    func setContext(_ context: NarrationRenderer.ExecutionContext, cpuBudget: Double?) async {
        if case .mlx(let engine) = self { await engine.setBackend(context == .background ? .cpu : .gpu) }
        await setBudget(cpuBudget, context: context)
    }
    func setBudget(_ fraction: Double?, context: NarrationRenderer.ExecutionContext) async {
        switch self {
        case .coreML(let engine): await engine.setCPUBudgetFraction(context == .foreground ? nil : fraction)
        case .mlx(let engine): await engine.setCPUBudgetFraction(fraction)
        }
    }
    func setObserver(_ observer: (@Sendable (PocketTTSResourceSnapshot) -> Void)?) async {
        switch self {
        case .coreML(let engine): await engine.setResourceObserver(observer)
        case .mlx(let engine): await engine.setResourceObserver(observer)
        }
    }
    func synthesize(_ unit: BookNarrationUnit) async throws -> [Float] {
        let sampling = unit.pocketSampling ?? .init()
        try sampling.validate()
        switch self {
        case .coreML(let engine):
            return try await engine.synthesize(unit.synthesisText, voiceID: unit.voiceID,
                temperature: sampling.temperature, chunking: unit.pocketChunking ?? .init(),
                role: unit.role == .dialogue ? .dialogue : .narration, samplerSteps: sampling.samplerSteps,
                deliveryStyle: unit.pocketDeliveryStyle ?? .original).samples
        case .mlx(let engine):
            return try await engine.synthesize(unit.synthesisText, voiceID: unit.voiceID,
                temperature: sampling.temperature, chunking: unit.pocketChunking ?? .init(),
                role: unit.role == .dialogue ? .dialogue : .narration, samplerSteps: sampling.samplerSteps,
                deliveryStyle: unit.pocketDeliveryStyle ?? .original).samples
        }
    }
    func renderFrames(_ unit: BookNarrationUnit,
                      onTextChunk: @Sendable (PocketTTSChunkProgress) throws -> Void,
                      receive: @Sendable ([Float]) throws -> Void) async throws {
        let sampling = unit.pocketSampling ?? .init()
        try sampling.validate()
        switch self {
        case .coreML(let engine):
            try await engine.renderFrames(unit.synthesisText, voiceID: unit.voiceID,
                temperature: sampling.temperature, chunking: unit.pocketChunking ?? .init(),
                role: unit.role == .dialogue ? .dialogue : .narration, samplerSteps: sampling.samplerSteps,
                deliveryStyle: unit.pocketDeliveryStyle ?? .original, onTextChunk: onTextChunk, receive: receive)
        case .mlx(let engine):
            try await engine.renderFrames(unit.synthesisText, voiceID: unit.voiceID,
                temperature: sampling.temperature, chunking: unit.pocketChunking ?? .init(),
                role: unit.role == .dialogue ? .dialogue : .narration, samplerSteps: sampling.samplerSteps,
                deliveryStyle: unit.pocketDeliveryStyle ?? .original, onTextChunk: onTextChunk, receive: receive)
        }
    }
}
