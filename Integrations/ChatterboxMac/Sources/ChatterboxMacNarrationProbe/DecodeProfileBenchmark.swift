#if os(macOS)
import Foundation
import CryptoKit
import Darwin
import MLX
import ChatterboxCoreML
import LibroxChatterbox
import LibroxChatterboxMLX
import ChatterboxMacAcousticAudit

/// Diagnostic only: transports actual decoded tokens through the existing seam.
/// The one zero sample is an internal sentinel. It is never exported or cached.
private actor NoAudioProfileSink: ChatterboxAcousticSynthesizing {
    private var pending: [Int]?
    func renderMeasured(tokens: [Int], conditioningFile: URL?) throws -> ChatterboxAcousticOutput {
        try Task.checkCancellation()
        guard pending == nil, !tokens.isEmpty, tokens.count <= 350,
              tokens.allSatisfy({ (0..<6561).contains($0) }) else { throw AcousticInventoryError.input }
        pending = tokens
        return .init(samples: [0], timings: .init())
    }
    func take() throws -> [Int] {
        guard let pending else { throw AcousticInventoryError.input }
        self.pending = nil; return pending
    }
}

enum MacDecoderProfileBenchmark {
    struct Input: Codable { let language, text: String }
    struct Configuration: Decodable {
        let metallib, backbone, oracle, modelDirectory, voice, outputDirectory: String
        let inputs: [Input]
    }
    struct Arm: Codable {
        let id, language, inputSHA256, tokensSHA256: String
        let profiling: Bool
        let tokens: [Int]
        let wallSeconds: Double
        let prefillSeconds, decodeSeconds, assemblySeconds: Double?
        let stages: DecodeStepTimings?
    }
    struct Report: Encodable {
        let state, rendererProfile, decoderWeightsSHA256, oracleSHA256, stockSHA256: String
        let coldLoadSeconds: Double
        let arms: [Arm]
        let tokenIdentityValidated, acousticsExecuted, audioExported, cloudUsed: Bool
    }
    static func run(configuration path: String) async throws {
        guard ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0" else { throw AcousticInventoryError.input }
        let f = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? f.close() }
        let bytes = try f.read(upToCount: 65_537) ?? Data()
        guard bytes.count <= 65_536 else { throw AcousticInventoryError.input }
        let c = try JSONDecoder().decode(Configuration.self, from: bytes)
        guard c.inputs.map(\.language) == ["en", "es"],
              c.inputs.allSatisfy({ !$0.text.isEmpty && $0.text.utf8.count <= 2_048 }) else { throw AcousticInventoryError.input }
        let output = URL(fileURLWithPath: c.outputDirectory)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw AcousticInventoryError.input }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var stage = "loading-standard-decoder"
        try write(["stage": stage], to: output.appendingPathComponent("status.json"))
        let priorFlag = ProcessInfo.processInfo.environment["CHATTERBOX_PROFILE_DECODE"]
        defer {
            if let priorFlag { setenv("CHATTERBOX_PROFILE_DECODE", priorFlag, 1) }
            else { unsetenv("CHATTERBOX_PROFILE_DECODE") }
        }
        do {
            let began = Date()
            let runtime = try ChatterboxMacRuntime(metallib: URL(fileURLWithPath: c.metallib))
            ChatterboxMLXRenderer.configureBufferCache(maximumBytes: 256 * 1024 * 1024)
            let voice = URL(fileURLWithPath: c.voice)
            guard try MacNarrationProbe.hash(voice) == ChatterboxMacAcousticSynthesizer.stockSHA256 else { throw AcousticInventoryError.identity }
            let sink = NoAudioProfileSink()
            let backend = try ChatterboxAcousticBackend(identifier: "diagnostic-no-audio-decode-profile-1",
                watermarkPolicy: .disabled, synthesizer: sink)
            let renderer = try await ChatterboxMLXRenderer(weightsFile: URL(fileURLWithPath: c.backbone),
                oracleFile: URL(fileURLWithPath: c.oracle), modelDirectory: URL(fileURLWithPath: c.modelDirectory),
                defaultVoice: voice, watermarkDirectory: output.appendingPathComponent("never-load-perth"),
                acousticComputeUnits: .init(), watermarkPolicy: .disabled, acousticBackend: backend)
            let loaded = Date().timeIntervalSince(began)
            print("Standard decoder ready after \(loaded)s; no acoustic model loaded"); fflush(stdout)
            var arms: [Arm] = []
            for profile in [false, true] {
                guard setenv("CHATTERBOX_PROFILE_DECODE", profile ? "1" : "0", 1) == 0 else { throw AcousticInventoryError.input }
                for input in c.inputs {
                    try Task.checkCancellation(); try runtime.verify()
                    stage = "profiling-\(profile ? "on" : "off")-\(input.language)"
                    try write(["stage": stage], to: output.appendingPathComponent("status.json"))
                    let request = try ChatterboxRequest(text: input.text, language: input.language, conditioningFile: voice,
                        exaggeration: 0.9, guidance: 0.3, temperature: 0.8, maxTokens: 350, seed: 42)
                    let start = Date(), sentinel = try await renderer.render(request)
                    let wall = Date().timeIntervalSince(start), tokens = try await sink.take()
                    var tokenBytes = Data()
                    for token in tokens { var v = Int32(token).littleEndian; withUnsafeBytes(of: &v) { tokenBytes.append(contentsOf: $0) } }
                    arms.append(.init(id: stage, language: input.language,
                        inputSHA256: digest(Data(input.text.utf8)), tokensSHA256: digest(tokenBytes), profiling: profile,
                        tokens: tokens, wallSeconds: wall, prefillSeconds: sentinel.timings?.prefillSeconds,
                        decodeSeconds: sentinel.timings?.decodeSeconds, assemblySeconds: sentinel.timings?.hostAssemblySeconds,
                        stages: sentinel.timings?.decodeSteps))
                    try write(arms, to: output.appendingPathComponent("arms-incomplete.json"))
                    guard sentinel.samples == [0], let timings = sentinel.timings,
                          (timings.decodeSteps != nil) == profile else { throw AcousticInventoryError.identity }
                    guard timings.speechTokens == tokens.count else { throw AcousticInventoryError.identity }
                    if let stages = timings.decodeSteps {
                        let values = [stages.inputPreparationSeconds, stages.predictionSeconds,
                            stages.logitsCopyAndCFGSeconds, stages.samplingSeconds, stages.resourceGuardSeconds ?? -1,
                            stages.graphConstructionSeconds ?? -1, stages.evaluationSeconds ?? -1]
                        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), stages.iterations > tokens.count,
                              stages.iterations <= 350, stages.accountedSeconds <= wall + 0.001,
                              (stages.graphConstructionSeconds ?? .infinity) + (stages.evaluationSeconds ?? .infinity) <= stages.predictionSeconds + 0.001
                        else { throw AcousticInventoryError.identity }
                    }
                    print("\(stage): \(tokens.count) tokens, \(wall)s"); fflush(stdout)
                }
            }
            for language in ["en", "es"] {
                guard let a = arms.first(where: { $0.language == language && !$0.profiling }),
                      let b = arms.first(where: { $0.language == language && $0.profiling }),
                      a.tokens == b.tokens, a.tokensSHA256 == b.tokensSHA256 else { throw AcousticInventoryError.identity }
            }
            try runtime.verify(); try Task.checkCancellation()
            let report = Report(state: "complete_numeric_decoder_profile", rendererProfile: renderer.profileIdentifier,
                decoderWeightsSHA256: renderer.decoderProfile.weightsSHA256, oracleSHA256: renderer.decoderProfile.oracleSHA256,
                stockSHA256: ChatterboxMacAcousticSynthesizer.stockSHA256, coldLoadSeconds: loaded,
                arms: arms, tokenIdentityValidated: true, acousticsExecuted: false, audioExported: false, cloudUsed: false)
            try write(["stage": "complete"], to: output.appendingPathComponent("status.json"))
            try runtime.verify(); try Task.checkCancellation()
            try write(report, to: output.appendingPathComponent("report.json"))
        } catch {
            try? write(["stage": stage, "failure": String(describing: error)], to: output.appendingPathComponent("failed.json"))
            throw error
        }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}
#endif
