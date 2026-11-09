import Foundation
import Testing
import LibroxTTS
import KokoroPronunciation
import PocketTTSMLX
import Synchronization

@Test func pocketNewBookDefaultsMatchAcceptedNarratorAndPreserveSavedSelections() async throws {
    let pipeline = NarrationPipeline()
    let source = "The rain had stopped. Beside the window, James closed his book."
    for language in PocketTTSCatalog.languages {
        let preset = try PocketTTSNarratorPreset.defaultNarrator(language: language)
        let plan = try await pipeline.plan(source, model: .pocket, bookID: "new", chapterID: "one",
                                          narratorVoiceID: nil, language: language)
        #expect(plan.narratorVoiceID == preset.voiceID)
        #expect(plan.units.allSatisfy { $0.voiceID == preset.voiceID && $0.pocketDeliveryStyle == .calm
            && $0.pocketChunking == preset.chunking && $0.pocketSampling == preset.sampling })
        let manifest = try NarrationAssets.manifestPocketNarratorPreset(language: language)
        #expect(Set(manifest.files.map(\.path)).count == manifest.files.count)
        #expect(manifest.files.contains { $0.path == "\(language)/embeddings/caro_davy__calm.safetensors" })
        #expect(manifest.files.contains { $0.path.hasSuffix("DELIVERY-CREDITS.json") })
    }
    let explicit = try await pipeline.plan(source, model: .pocket, bookID: "old", chapterID: "one",
                                          narratorVoiceID: "pocket-alba-en-v1", language: "en")
    #expect(explicit.narratorVoiceID == "pocket-alba-en-v1")
    #expect(explicit.units.allSatisfy { $0.pocketDeliveryStyle == nil && $0.pocketChunking == .init() })
    let cast = try BookVoiceCast(bookID: "old", languageCode: "en", narratorVoiceID: "pocket-alba-en-v1", voicePool: [])
    let saved = try await pipeline.plan(source, model: .pocket, bookID: "old", chapterID: "one",
                                       narratorVoiceID: nil, language: "en", cast: cast)
    #expect(saved.narratorVoiceID == "pocket-alba-en-v1")
    #expect(saved.units.allSatisfy { $0.pocketDeliveryStyle == nil && $0.voiceID == "pocket-alba-en-v1" })
    let original = try await pipeline.plan(source, model: .pocket, bookID: "new", chapterID: "two",
        narratorVoiceID: nil, language: "en", pocketChunking: .init(), pocketDelivery: .init())
    #expect(original.units.allSatisfy { $0.pocketDeliveryStyle == nil && $0.pocketChunking == .init() })
    #expect(!PocketTTSDeliveryCatalog.isPreview(voiceID: "pocket-caro_davy-en-v1", style: .calm))
    #expect(PocketTTSDeliveryCatalog.isPreview(voiceID: "pocket-caro_davy-es-v1", style: .calm))
    #expect(PocketTTSDeliveryCatalog.isPreview(voiceID: "pocket-peter_yearsley-en-v1", style: .calm))
}

@Test func pocketDeliveryPreservesOriginalCacheAndSeparatesPerformances() throws {
    try PocketTTSChunkingOptions.carefulReading.validate()
    #expect(PocketTTSChunkingOptions.carefulReading.cacheIdentity != PocketTTSChunkingOptions().cacheIdentity)
    var unit = BookNarrationUnit(sourceText: "She waited.",
        sourceRange: NSRange(location: 0, length: 11), narratorID: "pocket-caro_davy-en-v1")
    let original = NarrationModel.pocket.renderIdentity(for: unit)
    unit.pocketDeliveryStyle = .original
    #expect(NarrationModel.pocket.renderIdentity(for: unit) == original)
    var keys = Set<String>()
    for style in PocketTTSDeliveryStyle.allCases {
        unit.pocketDeliveryStyle = style
        keys.insert(NarrationModel.pocket.renderIdentity(for: unit))
    }
    #expect(keys.count == PocketTTSDeliveryStyle.allCases.count)
    #expect(NarrationModel.pocket.supportsReferenceDeliveryStyles)
    #expect(!NarrationModel.plus.supportsReferenceDeliveryStyles)
}

@Test func pocketDeliveryRoutesByRoleAndStableSpeakerWithoutChangingSource() throws {
    let voice = "pocket-caro_davy-en-v1"
    let narrator = BookNarrationUnit(sourceText: "She waited.",
        sourceRange: NSRange(location: 0, length: 11), narratorID: voice, role: .narration)
    let attribution = BookNarrationUnit(sourceText: "she said.",
        sourceRange: NSRange(location: 12, length: 9), narratorID: voice, role: .attribution)
    let dialogue = BookNarrationUnit(sourceText: "Stay.",
        sourceRange: NSRange(location: 22, length: 5), narratorID: voice, role: .dialogue, speakerID: "clara")
    let unknown = BookNarrationUnit(sourceText: "Who?",
        sourceRange: NSRange(location: 28, length: 4), narratorID: voice, role: .dialogue)
    let delivery = PocketTTSBookDelivery(narratorStyle: .calm, characterStyles: ["clara": .worried])
    let input = [narrator, attribution, dialogue, unknown]
    let output = try delivery.applying(to: input)
    #expect(output.map(\.pocketDeliveryStyle) == [.calm, .calm, .worried, nil])
    for (before, after) in zip(input, output) {
        #expect(before.text == after.text)
        #expect(before.range == after.range)
        #expect(before.voiceID == after.voiceID)
        #expect(before.speakerID == after.speakerID)
    }
    #expect(try JSONDecoder().decode(PocketTTSBookDelivery.self,
        from: JSONEncoder().encode(delivery)) == delivery)
    let a = PocketTTSBookDelivery(characterStyles: ["clara": .calm, "josé:|=": .happy])
    let b = PocketTTSBookDelivery(characterStyles: ["josé:|=": .happy, "clara": .calm])
    #expect(a.cacheIdentity == b.cacheIdentity)
    #expect(a.cacheIdentity != delivery.cacheIdentity)
}

@Test func pocketDeliveryFlowsThroughBookPlanningAndRejectsUnsupportedVoices() async throws {
    let source = "She waited by the window.\n\nThe rain had stopped."
    let plan = try await NarrationPipeline().plan(source, model: .pocket,
        bookID: "book", chapterID: "chapter", narratorVoiceID: "pocket-caro_davy-en-v1", language: "en",
        pocketDelivery: .init(narratorStyle: .calm))
    #expect(!plan.units.isEmpty)
    #expect(plan.units.allSatisfy { $0.pocketDeliveryStyle == .calm })
    for unit in plan.units { #expect((source as NSString).substring(with: unit.range) == unit.text) }
    await #expect(throws: PocketTTSDeliveryCatalog.DeliveryError.self) {
        try await NarrationPipeline().plan(source, model: .pocket,
            bookID: "book", chapterID: "chapter", narratorVoiceID: "pocket-alba-en-v1", language: "en",
            pocketDelivery: .init(narratorStyle: .calm))
    }
}

@Test func pocketDeliveryNeverAdvertisesUnexportedStates() throws {
    #expect(PocketTTSDeliveryCatalog.publishedStyles(voiceID: "invalid").isEmpty)
    #expect(PocketTTSDeliveryCatalog.publishedStyles(voiceID: "pocket-alba-en-v1") == [.original])
    for language in PocketTTSCatalog.languages {
        for name in PocketTTSDeliveryCatalog.referenceVoiceNames {
            let voiceID = "pocket-\(name)-\(language)-v1"
            let published = PocketTTSDeliveryCatalog.publishedStyles(voiceID: voiceID)
            #expect(published.first == .original)
            for style in published where style != .original {
                let state = try PocketTTSDeliveryCatalog.stateName(voiceID: voiceID, style: style)
                #expect(try PocketTTSDeliveryCatalog.manifest(language: language).installedFiles.contains {
                    $0.path == "\(language)/embeddings/\(state).safetensors"
                })
                let single = try PocketTTSDeliveryCatalog.manifest(voiceID: voiceID, style: style)
                #expect(single.files.filter { $0.path.contains("/embeddings/") }.count == 1)
                #expect(single.files.contains { $0.path.hasSuffix("DELIVERY-CREDITS.json") })
                #expect(style.isPreview)
            }
        }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_DELIVERY_SMOKE_OUTPUT"] != nil))
func pocketDeliveryAllExportedStatesRender() async throws {
    PocketTestMetal.configure()
    let env = ProcessInfo.processInfo.environment
    let engine = PocketTTSEngine(directory: URL(fileURLWithPath: env["POCKET_DELIVERY_ASSETS"]!))
    let texts = ["en": "She opened the book.", "es": "Ella abrió el libro.",
                 "fr": "Elle ouvrit le livre.", "de": "Sie öffnete das Buch.",
                 "it": "Lei aprì il libro.", "pt": "Ela abriu o livro.", "nl": "Ze opende het boek."]
    var rows: [[String: String]] = []
    let destination = URL(fileURLWithPath: env["POCKET_DELIVERY_SMOKE_OUTPUT"]!)
    for language in PocketTTSCatalog.languages {
        for voice in PocketTTSDeliveryCatalog.referenceVoiceNames {
            for style in PocketTTSDeliveryStyle.allCases where style != .original {
                await engine.setRandomSeed(42)
                let audio = try await engine.synthesize(texts[language]!, voiceID: "pocket-\(voice)-\(language)-v1",
                    deliveryStyle: style)
                #expect(!audio.samples.isEmpty)
                #expect(audio.samples.allSatisfy { $0.isFinite })
                #expect(audio.samples.count < 24_000 * 30)
                rows.append(["language": language, "voice": voice, "style": style.rawValue,
                             "samples": String(audio.samples.count)])
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
            }
        }
    }
    #expect(rows.count == 364)
    await engine.unload()
}

@Test func pocketMissingStyleFailsBeforeGPUAllocationOnBothEntryPoints() async throws {
    // No model or Metal is needed to reject an absent optional style.
    let engine = PocketTTSEngine(directory: URL(fileURLWithPath: "/nonexistent/max-style-test"))
    await #expect(throws: PocketTTSDeliveryCatalog.DeliveryError.self) {
        try await engine.synthesize("Please stay.", voiceID: "pocket-caro_davy-en-v1", deliveryStyle: .worried)
    }
    await #expect(throws: PocketTTSDeliveryCatalog.DeliveryError.self) {
        try await engine.renderFrames("Please stay.", voiceID: "pocket-caro_davy-en-v1", deliveryStyle: .worried) { _ in
            Issue.record("Missing style must never emit substituted audio")
        }
    }
}

/// Real exported states only. This establishes routing and state isolation,
/// not whether the performance sounds calm, worried, or suitable for a book.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_DELIVERY_ASSETS"] != nil),
      arguments: [PocketTTSEngine.Backend.cpu, .gpu])
func pocketDeliveryRealStatePipelineParity(backend: PocketTTSEngine.Backend) async throws {
    PocketTestMetal.configure()
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_DELIVERY_ASSETS"]!)
    let renderer = NarrationRenderer(compactDirectory: URL(fileURLWithPath: "/unused"), harmonicSource: nil)
    try await renderer.load(.pocket, directory: directory,
        executionContext: backend == .cpu ? .background : .foreground)
    let direct = PocketTTSEngine(directory: directory, backend: backend)
    for (language, text) in [("en", "She opened the book and began to read."),
                              ("es", "Abrió el libro y empezó a leer.")] {
        let voiceID = "pocket-caro_davy-\(language)-v1"
        var original: [Float] = []
        for style: PocketTTSDeliveryStyle in [.original, .calm, .worried, .original] {
            let plan = try await NarrationPipeline().plan(text, model: .pocket,
                bookID: "test", chapterID: "styles", narratorVoiceID: voiceID, language: language,
                pocketSampling: .init(temperature: 0), pocketDelivery: .init(narratorStyle: style))
            let unit = try #require(plan.units.first)
            let actual = try await renderer.render(unit)
            let expected = try await direct.synthesize(unit.synthesisText, voiceID: voiceID,
                temperature: 0, deliveryStyle: style).samples
            #expect(actual.count > 24_000)
            #expect(actual.allSatisfy { $0.isFinite })
            #expect(actual.count == expected.count)
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000001 })
            let frames = Mutex<[Float]>([])
            try await direct.renderFrames(unit.synthesisText, voiceID: voiceID, temperature: 0,
                deliveryStyle: style) { chunk in frames.withLock { $0.append(contentsOf: chunk) } }
            #expect(frames.withLock { $0 } == expected)
            if style == .original {
                if original.isEmpty { original = actual }
                else { #expect(actual == original) }
            }
        }
    }
    await direct.unload()
    await renderer.unload()
}
