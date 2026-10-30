#if os(macOS)
import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit
import MLX
import ChatterboxCoreML
import LibroxChatterbox
import LibroxChatterboxMLX
import ChatterboxMacAcousticAudit
import Darwin

struct BookAudition: Codable {
    let sourceFile, sourceSHA256: String
    let offsetUTF16, lengthUTF16: Int
    let exaggeration, guidance, temperature: Float
    func directions(for excerpt: String) throws -> ChatterboxPerformanceDirections {
        let f = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourceFile)); defer { try? f.close() }
        let data = try f.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sourceSHA256,
              let source = String(data: data, encoding: .utf8), offsetUTF16 >= 0, lengthUTF16 > 0,
              offsetUTF16 <= (source as NSString).length, lengthUTF16 <= (source as NSString).length - offsetUTF16,
              let range = Range(NSRange(location: offsetUTF16, length: lengthUTF16), in: source),
              Data(source[range].utf8) == Data(excerpt.utf8) else { throw AcousticInventoryError.identity }
        return try .init(source: excerpt, annotations: [.init(range: .init(location: 0, length: excerpt.utf16.count),
            originalText: excerpt, controls: .init(exaggeration: exaggeration, guidance: guidance, temperature: temperature))])
    }
}
struct Configuration: Decodable {
    let checkpoint, metallib, backbone, oracle, modelDirectory, voice, watermarkDirectory, outputDirectory: String
    let variant, watermark: String
    let overlap, grouped: Bool
    let texts: [String: String]
    let residentControls: Bool?
    let waveformPolicy: String?
    let bookAudition: BookAudition?
}
struct Trial: Codable {
    let id: String
    let grouped, overlap: Bool
    static let resident = [Trial(id: "sentences-serial", grouped: false, overlap: false),
        Trial(id: "sentences-overlap", grouped: false, overlap: true),
        Trial(id: "grouped160-serial", grouped: true, overlap: false),
        Trial(id: "grouped160-overlap", grouped: true, overlap: true),
        Trial(id: "sentences-repeat", grouped: false, overlap: false)]
}
struct Passage: Codable, Sendable {
    let index, firstFrame, frames, generatedFrames, sourceLocation, sourceLength, speechTokens: Int
    let arrivalSeconds, prefillSeconds, decodeSeconds, synthSeconds, watermarkSeconds: Double
    let acoustics: ChatterboxAcousticTimings?
    let exaggeration, guidance, temperature: Float
}
actor Collector {
    var samples: [Float] = []
    var passages: [Passage] = []
    let began: Date
    let metrics: URL
    init(began: Date, metrics: URL) { self.began = began; self.metrics = metrics }
    func append(_ p: ChatterboxPreparedPassage) throws {
        guard samples.count + p.samples.count <= 120 * 24000, !p.cacheHit else { throw AcousticInventoryError.input }
        let range = p.unit.request.sourceContext!.range
        passages.append(.init(index: p.index, firstFrame: samples.count, frames: p.samples.count,
            generatedFrames: p.generatedFrames, sourceLocation: range.location, sourceLength: range.length,
            speechTokens: p.timings?.speechTokens ?? 0, arrivalSeconds: Date().timeIntervalSince(began),
            prefillSeconds: p.timings?.prefillSeconds ?? 0, decodeSeconds: p.timings?.decodeSeconds ?? 0,
            synthSeconds: p.timings?.synthSeconds ?? 0, watermarkSeconds: p.timings?.watermarkSeconds ?? 0,
            acoustics: p.timings?.acoustics, exaggeration: p.unit.request.exaggeration,
            guidance: p.unit.request.guidance, temperature: p.unit.request.temperature))
        samples += p.samples
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(passages).write(to: metrics, options: .atomic)
        print("passage \(p.index) ready, \(samples.count) total frames")
        fflush(stdout)
    }
    func result() -> ([Float], [Passage]) { (samples, passages) }
}
typealias Export = NativeAudioExportReport
struct Status: Encodable { let completed: Bool; let stage: String }
struct LanguageResult: Codable {
    let language, text, rendererProfile, trialID, pcmSHA256, deliveryMode: String
    let grouped, overlap: Bool
    let audioSeconds, renderSeconds, exportSeconds, completeWarmSeconds, completeWarmRTF, playbackMultiple, firstPassageSeconds: Double
    let peak, rms: Float
    let passages: [Passage]
    let exports: [Export]
}
struct ProgramResult: Codable {
    let state, variant, watermark, decoderWeightsSHA256, acousticCheckpointSHA256, stockSHA256: String
    let overlap, grouped: Bool
    let coldLoadSeconds, totalColdWallSeconds: Double
    let results: [LanguageResult]
    let trials: [Trial]
    let pcmIdentityValidated: Bool?
    let waveformPolicy: String
    let bookAudition: BookAudition?
    let userListeningApproved, fiveTimesPlaybackEstablished, cloudUploadMeasured: Bool
}

@main struct MacNarrationProbe {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args.count == 2, args[0] == "--codecs" { try MacCodecBenchmark.run(configuration: args[1]) }
            else { try await run() }
        }
        catch {
            FileHandle.standardError.write(Data(("narration_failed: " + String(describing: error).prefix(1024) + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
    static func run() async throws {
        let began = Date(), args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 1, ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0" else { throw AcousticInventoryError.input }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: args[0])); defer { try? input.close() }
        let bytes = try input.read(upToCount: 65537) ?? Data()
        guard bytes.count <= 65536 else { throw AcousticInventoryError.input }
        let c = try JSONDecoder().decode(Configuration.self, from: bytes)
        guard let waveformPolicy = NativeAcousticWaveformPolicy(rawValue: c.waveformPolicy ?? "legacy-atomic-1") else { throw AcousticInventoryError.input }
        guard c.variant == "native" || waveformPolicy == .legacyAtomic else { throw AcousticInventoryError.input }
        let languages = c.bookAudition == nil ? ["en", "es"] : ["en"]
        guard ["native", "standard"].contains(c.variant), Set(c.texts.keys) == Set(languages),
              c.texts.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }),
              c.watermark == "disabled-1", let wm = ChatterboxWatermarkPolicy(rawValue: c.watermark) else { throw AcousticInventoryError.input }
        let bookDirections: ChatterboxPerformanceDirections?
        if let book = c.bookAudition {
            guard c.variant == "native", c.residentControls != true, c.grouped, c.overlap,
                  waveformPolicy == .deterministicGather else { throw AcousticInventoryError.input }
            bookDirections = try book.directions(for: c.texts["en"]!)
        } else { bookDirections = nil }
        if c.residentControls == true {
            guard c.variant == "native", !c.overlap, !c.grouped else { throw AcousticInventoryError.input }
        }
        let trials = c.residentControls == true ? Trial.resident : [Trial(id: "default", grouped: c.grouped, overlap: c.overlap)]
        let output = URL(fileURLWithPath: c.outputDirectory)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw AcousticInventoryError.input }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var stage = "loading-models"
        try json(Status(completed: false, stage: stage)).write(to: output.appendingPathComponent("status.json"), options: .atomic)
        do {
        let runtime = try ChatterboxMacRuntime(metallib: URL(fileURLWithPath: c.metallib))
        ChatterboxMLXRenderer.configureBufferCache(maximumBytes: 256 * 1024 * 1024)
        let voice = URL(fileURLWithPath: c.voice)
        guard try hash(voice) == ChatterboxMacAcousticSynthesizer.stockSHA256 else { throw AcousticInventoryError.identity }
        var backend: ChatterboxAcousticBackend?
        let native: ChatterboxMacAcousticSynthesizer?
        if c.variant == "native" {
            native = try ChatterboxMacAcousticSynthesizer(checkpoint: URL(fileURLWithPath: c.checkpoint),
                metallib: URL(fileURLWithPath: c.metallib), stockConditioning: voice, waveformPolicy: waveformPolicy)
            backend = try native!.backend()
            try await native!.loadingReport().write(to: output.appendingPathComponent("acoustic-load.json"), options: .atomic)
        } else { native = nil }
        let renderer = try await ChatterboxMLXRenderer(weightsFile: URL(fileURLWithPath: c.backbone),
            oracleFile: URL(fileURLWithPath: c.oracle), modelDirectory: URL(fileURLWithPath: c.modelDirectory),
            defaultVoice: voice, watermarkDirectory: URL(fileURLWithPath: c.watermarkDirectory),
            acousticComputeUnits: .init(encoder: .cpuOnly, cfm: .cpuOnly, vocoder: .cpuOnly, watermark: .cpuOnly),
            watermarkPolicy: wm, acousticBackend: backend)
        let loaded = Date().timeIntervalSince(began)
        print("models ready after \(loaded)s; profile \(renderer.profileIdentifier)");fflush(stdout)
        var results: [LanguageResult] = []
        for trial in trials {
        let trialOutput = trial.id == "default" ? output : output.appendingPathComponent(trial.id)
        if trial.id != "default" { try FileManager.default.createDirectory(at: trialOutput, withIntermediateDirectories: false) }
        for language in languages {
            try Task.checkCancellation(); try runtime.verify()
            let start = Date(), collector = Collector(began: start, metrics: trialOutput.appendingPathComponent(language + "-passages-incomplete.json"))
            let narrator = await renderer.makeNarrator(overlap: trial.overlap)
            let cache = trialOutput.appendingPathComponent(language + "-cache")
            let manifest = SHA256.hash(data: Data((ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate.weightsSHA256 +
                (c.variant == "native" ? AcousticInventory.checkpointSHA256 : "standard-coreml") + c.watermark).utf8)).map { String(format: "%02x", $0) }.joined()
            let session = try ChatterboxBookSession(narrator: narrator, cacheDirectory: cache,
                modelManifestSHA256: manifest, rendererProfile: renderer.profileIdentifier)
            stage = trial.id + "/rendering-" + language
            try json(Status(completed: false, stage: stage)).write(to: output.appendingPathComponent("status.json"), options: .atomic)
            do {
            try await session.stream(c.texts[language]!, language: language, narratorID: "stock",
                conditioningFiles: ["stock": voice], conditioningSHA256: ["stock": ChatterboxMacAcousticSynthesizer.stockSHA256],
                direction: .storyteller, grouping: trial.grouped ? .compatibleNarration(maxCharacters: 160) : .sentences,
                seed: 42, performanceDirections: bookDirections, preparation: .finiteExcerpt) { p in try await collector.append(p) }
            } catch {
                try? await narrator.unload()
                throw error
            }
            try await narrator.unload()
            let renderSeconds = Date().timeIntervalSince(start), (samples, passages) = await collector.result()
            guard !samples.isEmpty, !passages.isEmpty, samples.allSatisfy(\.isFinite) else { throw AcousticInventoryError.input }
            stage = trial.id + "/encoding-verifying-" + language
            try json(Status(completed: false, stage: stage)).write(to: output.appendingPathComponent("status.json"), options: .atomic)
            let exportBegan = Date()
            var exports: [Export] = []
            if c.bookAudition != nil {
                exports.append(try NativeAudioExport.write(samples, to: trialOutput.appendingPathComponent(language + "-smaller.m4a"), codec: .aac64))
            } else {
            if c.residentControls != true {
                exports.append(try NativeAudioExport.write(samples, to: trialOutput.appendingPathComponent(language + ".wav"), lossless: false))
            }
            exports.append(try NativeAudioExport.write(samples, to: trialOutput.appendingPathComponent(language + "-lossless.m4a"), lossless: true))
            }
            guard exports.allSatisfy(\.frameCountMatches) else { throw AcousticInventoryError.identity }
            let exportSeconds = Date().timeIntervalSince(exportBegan), complete = Date().timeIntervalSince(start)
            let duration = Double(samples.count) / 24000
            // Raw-PCM identity is an analysis control outside product delivery timing.
            let pcmSHA = samples.withUnsafeBufferPointer { SHA256.hash(data: Data(buffer: $0)).map { String(format: "%02x", $0) }.joined() }
            let result = LanguageResult(language: language, text: c.texts[language]!, rendererProfile: renderer.profileIdentifier,
                trialID: trial.id, pcmSHA256: pcmSHA, deliveryMode: c.bookAudition != nil ? "AAC64-only" : (c.residentControls == true ? "ALAC24-only" : "WAVF32+ALAC24"),
                grouped: trial.grouped, overlap: trial.overlap,
                audioSeconds: duration, renderSeconds: renderSeconds, exportSeconds: exportSeconds,
                completeWarmSeconds: complete, completeWarmRTF: complete/duration, playbackMultiple: duration/complete,
                firstPassageSeconds: passages.first!.arrivalSeconds,
                peak: samples.reduce(0, { max($0, abs($1)) }), rms: sqrt(samples.reduce(0, { $0 + $1*$1 })/Float(samples.count)),
                passages: passages, exports: exports)
            results.append(result)
            try json(result).write(to: trialOutput.appendingPathComponent(language + "-report.json"), options: .atomic)
            print("\(trial.id)/\(language) complete: audio=\(duration)s wall=\(complete)s multiple=\(duration/complete)");fflush(stdout)
        }
        }
        if c.residentControls == true {
            for language in ["en", "es"] {
                for (a, b) in [("sentences-serial", "sentences-overlap"), ("grouped160-serial", "grouped160-overlap"), ("sentences-serial", "sentences-repeat")] {
                    stage = "validating-pcm/" + language + "/" + a + "/" + b
                    guard let left = results.first(where: { $0.language == language && $0.trialID == a }),
                          let right = results.first(where: { $0.language == language && $0.trialID == b }),
                          left.pcmSHA256 == right.pcmSHA256 else { throw AcousticInventoryError.identity }
                }
            }
        }
        try runtime.verify(); try Task.checkCancellation()
        let result = ProgramResult(state: "complete", variant: c.variant, watermark: c.watermark,
            decoderWeightsSHA256: ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate.weightsSHA256,
            acousticCheckpointSHA256: c.variant == "native" ? AcousticInventory.checkpointSHA256 : "standard-coreml-assets",
            stockSHA256: ChatterboxMacAcousticSynthesizer.stockSHA256,
            overlap: c.overlap, grouped: c.grouped, coldLoadSeconds: loaded,
            totalColdWallSeconds: Date().timeIntervalSince(began), results: results, trials: trials,
            pcmIdentityValidated: c.residentControls == true ? true : nil,
            waveformPolicy: c.variant == "native" ? waveformPolicy.rawValue : "standard-coreml-existing", bookAudition: c.bookAudition,
            userListeningApproved: false, fiveTimesPlaybackEstablished: false, cloudUploadMeasured: false)
        try json(Status(completed: true, stage: "complete")).write(to: output.appendingPathComponent("status.json"), options: .atomic)
        try json(result).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        _ = native
        } catch {
            struct Failure: Encodable { let completed: Bool; let stage, error: String }
            try? json(Failure(completed: false, stage: stage, error: String(describing: error)))
                .write(to: output.appendingPathComponent("failed.json"), options: .atomic)
            throw error
        }
    }
    static func json<T:Encodable>(_ value:T) throws -> Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(value)
    }
    static func hash(_ file:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:file);defer{try?handle.close()};var sha=SHA256()
        while let data=try handle.read(upToCount:1024*1024),!data.isEmpty{try Task.checkCancellation();sha.update(data:data)}
        return sha.finalize().map{String(format:"%02x",$0)}.joined()
    }

}
#else
@main struct MacNarrationProbe{static func main(){fatalError("Mac only")}}
#endif
