import Testing
import KokoroCatalog
@testable import PocketTTSMLX
@Test func catalogSeparatesLanguages() {
    #expect(PocketTTSCatalog.languages.count == 7)
    #expect(Set(PocketTTSCatalog.voices.map(\.id)).count == 161)
    #expect(PocketTTSCatalog.voice(id: "pocket-lola-es-v1")?.language == "es")
}

@Test func pocketDistributionOnlyIncludesReviewedRecordingSources() throws {
    let excluded = ["cosette", "jean", "juergen", "rafael"]
    for language in PocketTTSCatalog.languages {
        let manifest = try PocketTTSCatalog.manifest(language: language)
        let names = Set(manifest.files.filter { $0.path.contains("/embeddings/") }
            .map { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent })
        #expect(names == Set(PocketTTSCatalog.voiceNames))
        #expect(manifest.revision == PocketTTSCatalog.identity)
        #expect(names.contains(try #require(PocketTTSCatalog.defaultVoices[language])))
        for name in excluded {
            #expect(PocketTTSCatalog.voice(id: "pocket-\(name)-\(language)-v1") == nil)
            #expect(NarrationModel.pocket.resolvedVoiceID("pocket-\(name)-\(language)-v1", language: language) == nil)
        }
    }
    #expect(PocketTTSCatalog.voice(id: "pocket-alba-en-v1")?.sourceRecordingLicense == "CC-BY-4.0")
    #expect(PocketTTSCatalog.voice(id: "pocket-lola-es-v1")?.sourceRecordingLicense == "CC0-1.0")
}

import Foundation
import Synchronization
import MLX
import LibroxTTS

@Test func pocketPlanningPreservesSourceAndCast() async throws {
    let source = "“Wait,” said Maria.\n\nThe rain had stopped."
    let pipeline = NarrationPipeline()
    let plan = try await pipeline.plan(source, model: .pocket, bookID: "book", chapterID: "chapter",
        narratorVoiceID: "pocket-alba-en-v1", language: "en", characterVoices: true)
    #expect(plan.cast != nil)
    #expect(!plan.units.isEmpty)
    for unit in plan.units {
        #expect((source as NSString).substring(with: unit.range) == unit.text)
        #expect(unit.phonemes.isEmpty)
        #expect(unit.voiceID.hasPrefix("pocket-"))
    }
    #expect(NarrationModel.pocket.resolvedVoiceID(nil, language: "ja") == nil)
    #expect(NarrationModel.pocket.resolvedVoiceID(nil, language: "es") == "pocket-lola-es-v1")
    #expect(NarrationModel.pocket.resolvedVoiceID("pocket-cosette-en-v1", language: "en") == nil)
    #expect(NarrationModel.pocket.resolvedVoiceID("af_heart", language: "en") == nil)
    #expect(NarrationModel.pocket.isEnabled)
    #expect(!NarrationModel.pocket.isQwen)
    #expect(NarrationModel.pocket.requiresPreparation)
    #expect(!NarrationModel.pocket.supportsVoiceBlending)
    #expect(!NarrationModel.pocket.supportsExpressiveDelivery)
}

@Test func pocketRejectsBackgroundGPU() async throws {
    let renderer = NarrationRenderer(compactDirectory: URL(fileURLWithPath: "/unused"), harmonicSource: nil)
    await #expect(throws: NarrationRenderer.RenderError.self) {
        try await renderer.load(.pocket, directory: URL(fileURLWithPath: "/unused"), executionContext: .background)
    }
}

@Test func pocketSamplerStepsRejectInvalidValuesBeforeLoadingAssets() async throws {
    let engine = PocketTTSEngine(directory: URL(fileURLWithPath: "/unused"))
    for steps in [0, 9] {
        await #expect(throws: PocketTTSError.invalidSamplerSteps) {
            try await engine.synthesize("Hello.", voiceID: "pocket-alba-en-v1", samplerSteps: steps)
        }
        await #expect(throws: PocketTTSError.invalidSamplerSteps) {
            try await engine.renderFrames("Hello.", voiceID: "pocket-alba-en-v1", samplerSteps: steps) { _ in }
        }
    }
    for temperature: Float in [-1, .nan, .infinity] {
        await #expect(throws: PocketTTSSamplingOptions.ValidationError.self) {
            try await engine.synthesize("Hello.", voiceID: "pocket-alba-en-v1", temperature: temperature)
        }
        await #expect(throws: PocketTTSSamplingOptions.ValidationError.self) {
            try await engine.renderFrames("Hello.", voiceID: "pocket-alba-en-v1", temperature: temperature) { _ in }
        }
    }
}

@Test func pocketSamplingDefaultsToQualityAndCarriesExplicitFallbacksIntoCache() async throws {
    #expect(PocketTTSSamplingOptions().samplerSteps == 4)
    #expect(PocketTTSEngine.runtimeIdentity == NarrationModel.pocket.deliveryIdentity)
    let pipeline = NarrationPipeline()
    let source = "Clara was her sister. James was her brother.\n“Please stay,” said Clara.\n“No,” said James."
    let quality = try await pipeline.plan(source, model: .pocket, bookID: "book", chapterID: "one",
        narratorVoiceID: "pocket-alba-en-v1", language: "en", characterVoices: true)
    #expect(!quality.units.isEmpty)
    #expect(quality.units.allSatisfy { $0.pocketSampling?.samplerSteps == 4 })
    #expect(quality.bookPlan?.units.allSatisfy { $0.pocketSampling?.samplerSteps == 4 } == true)
    var unit = try #require(quality.units.first)
    let key = NarrationModel.pocket.renderIdentity(for: unit)
    unit.pocketSampling = nil
    #expect(NarrationModel.pocket.renderIdentity(for: unit) == key)
    for steps in [8, 2, 1] {
        let selected = PocketTTSSamplingOptions(temperature: 0.15, samplerSteps: steps)
        let plan = try await pipeline.plan(source, model: .pocket, bookID: "book", chapterID: "one",
            narratorVoiceID: "pocket-alba-en-v1", language: "en", pocketSampling: selected)
        #expect(plan.units.allSatisfy { $0.pocketSampling == selected })
        unit.pocketSampling = selected
        #expect(NarrationModel.pocket.renderIdentity(for: unit) != key)
        #expect(try JSONDecoder().decode(PocketTTSSamplingOptions.self,
            from: JSONEncoder().encode(selected)) == selected)
    }
    await #expect(throws: PocketTTSSamplingOptions.ValidationError.self) {
        try await pipeline.plan("Hello.", model: .pocket, bookID: "book", chapterID: "one",
            narratorVoiceID: "pocket-alba-en-v1", language: "en", pocketSampling: .init(samplerSteps: 0))
    }
    #expect(throws: PocketTTSSamplingOptions.ValidationError.self) {
        try PocketTTSSamplingOptions(temperature: .nan).validate()
    }
}

/// Opt-in numerical comparison against fixtures generated by the pinned CPU implementation.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_REFERENCE"] != nil))
func referenceLatents() throws {
    let env = ProcessInfo.processInfo.environment
    if let path = env["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
    let code = env["POCKET_LANGUAGE"] ?? "en"
    let assets = URL(fileURLWithPath: env["POCKET_ASSETS"]!)
    let ref = URL(fileURLWithPath: env["POCKET_REFERENCE"]!)
    let report = try JSONSerialization.jsonObject(with: Data(contentsOf: ref.appendingPathComponent("reference.json"))) as! [String: Any]
    let voice = env["POCKET_VOICE"] ?? (report["voice"] as? String) ?? PocketTTSCatalog.defaultVoices[code]!
    let model = try PocketTTSModel.fromModelDirectory(assets.appendingPathComponent(code))
    model.temp = 0
    let tokenizer = model.flow_lm.conditioner.tokenizer
    let text = report["text"] as! String
    #expect(tokenizer.encode(text) == report["tokens"] as! [Int])
    let chunks = try PocketTTSTextUtils.splitIntoBestSentences(tokenizer, text, maxTokens: 25, config: model.config)
    #expect(chunks == report["chunks"] as! [String])
    let state = try model.loadVoiceState(voice)
    let prompt = try PocketTTSTextUtils.prepareTextPrompt(chunks[0], config: model.config).0
    let tokens = model.flow_lm.conditioner.prepare(prompt)
    let embedding = model.flow_lm.conditioner(tokens)
    _ = model.flow_lm.transformer(embedding, cache: state.flowCache)
    let golden = try MLX.loadArrays(url: ref.appendingPathComponent("trace.safetensors"))
    var input = MLXArray.ones([1, 1, model.flow_lm.ldim]) * Float.nan
    for i in 1..<16 {
        let (latent, eos) = model.flow_lm(sequence: input, textEmbeddings: MLXArray.zeros([1, 0, model.flow_lm.dim]),
            cache: state.flowCache, lsdDecodeSteps: 1, temperature: 0, noiseClamp: nil, eosThreshold: -4)
        let expected = try #require(golden["latent_\(i)"])
        let error = MLX.max(MLX.abs(latent - expected)).item(Float.self)
        print("Pocket latent \(i) maximum absolute error \(error)")
        #expect(error < 0.0001)
        #expect(eos.item(Bool.self) == golden["eos_\(i)"]!.item(Bool.self))
        // Use identical reference inputs to isolate operator parity from chaotic autoregressive drift.
        input = expected.expandedDimensions(axis: 1)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_REFERENCE"] != nil))
func referenceDecoder() throws {
    let env = ProcessInfo.processInfo.environment
    if let path = env["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
    let code = env["POCKET_LANGUAGE"] ?? "en"
    let model = try PocketTTSModel.fromModelDirectory(URL(fileURLWithPath: env["POCKET_ASSETS"]!).appendingPathComponent(code))
    let golden = try MLX.loadArrays(url: URL(fileURLWithPath: env["POCKET_REFERENCE"]!).appendingPathComponent("trace.safetensors"))
    model.mimi.resetState()
    for i in 0..<16 {
        let latent = try #require(golden["decoder_latent_\(i)"])
        let expected = try #require(golden["decoder_audio_\(i)"])
        let audio = model.mimi.decodeStep(model.mimi.quantizer(latent.transposed(0, 2, 1)))
        #expect(audio.shape == expected.shape)
        let error = MLX.max(MLX.abs(audio - expected)).item(Float.self)
        print("Pocket decoder \(i) maximum absolute error \(error)")
        #expect(error < 0.0001)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
func pocketEndToEndPipeline() async throws {
    let env = ProcessInfo.processInfo.environment
    if let path = env["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
    let directory = URL(fileURLWithPath: env["POCKET_ASSETS"]!)
    let pipeline = NarrationPipeline()
    let plan = try await pipeline.plan("The library was quiet. She opened the book.", model: .pocket,
        bookID: "validation", chapterID: "one", narratorVoiceID: "pocket-alba-en-v1", language: "en")
    let renderer = NarrationRenderer(compactDirectory: URL(fileURLWithPath: "/unused"), harmonicSource: nil)
    try await renderer.load(.pocket, directory: directory, executionContext: .foreground)
    let audio = try await renderer.render(try #require(plan.units.first))
    #expect(audio.count > 24_000)
    #expect(audio.allSatisfy { $0.isFinite })
    await renderer.unload()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
func pocketRendererHonorsSamplingAndRestoresQualityAfterExplicitFallback() async throws {
    let env = ProcessInfo.processInfo.environment
    if let path = env["POCKET_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
    let directory = URL(fileURLWithPath: env["POCKET_ASSETS"]!)
    let pipeline = NarrationPipeline()
    let renderer = NarrationRenderer(compactDirectory: URL(fileURLWithPath: "/unused"), harmonicSource: nil)
    let direct = PocketTTSEngine(directory: directory)
    try await renderer.load(.pocket, directory: directory, executionContext: .foreground)
    var quality: [Float] = []
    for steps in [4, 1] {
        let plan = try await pipeline.plan("The library was quiet.", model: .pocket,
            bookID: "validation", chapterID: "sampling", narratorVoiceID: "pocket-alba-en-v1", language: "en",
            pocketSampling: .init(temperature: 0, samplerSteps: steps))
        let unit = try #require(plan.units.first)
        let actual = try await renderer.render(unit)
        let expected = try await direct.synthesize(unit.synthesisText, voiceID: unit.voiceID,
            temperature: 0, samplerSteps: steps).samples
        #expect(!actual.isEmpty)
        #expect(actual.count == expected.count)
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000001 })
        let frames = Mutex<[Float]>([])
        try await direct.renderFrames(unit.synthesisText, voiceID: unit.voiceID,
                                      temperature: 0, samplerSteps: steps) { chunk in
            frames.withLock { $0.append(contentsOf: chunk) }
        }
        let streamed = frames.withLock { $0 }
        #expect(streamed.count == expected.count)
        #expect(zip(streamed, expected).allSatisfy { abs($0 - $1) < 0.000001 })
        if steps == 4 { quality = expected }
    }
    // A preceding explicit fallback must not leak into later default requests.
    let restored = try await direct.synthesize("The library was quiet.", voiceID: "pocket-alba-en-v1", temperature: 0).samples
    #expect(restored.count == quality.count)
    #expect(zip(restored, quality).allSatisfy { abs($0 - $1) < 0.000001 })
    await renderer.unload()
    await direct.unload()
}
