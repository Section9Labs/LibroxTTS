import Foundation
import XCTest
import KokoroCatalog
import KokoroPronunciation
import LibroxTTS
import PocketTTSMLX
import PocketTTSCoreML

final class PocketImportedVoiceTests: XCTestCase {
    func testLegacyFunctionReferencesRemainAvailable() throws {
        // Default arguments on a replacement signature do not preserve these
        // function values. Keep the original overloads callable by old clients.
        let mlxFactory: (URL, PocketTTSEngine.Backend) -> PocketTTSEngine = PocketTTSEngine.init(directory:backend:)
        let coreFactory: (URL, URL?, PocketTTSCoreMLEngine.Placement) -> PocketTTSCoreMLEngine = PocketTTSCoreMLEngine.init(directory:modelsDirectory:placement:)
        let rendererFactory: (URL, Bundle, URL?) -> NarrationRenderer = NarrationRenderer.init(storageRoot:resources:expressionDirectory:)
        let directory = try folder()
        _ = mlxFactory(directory, .cpu)
        _ = coreFactory(directory, nil, .cpu)
        _ = rendererFactory(directory, .main, nil)
        let resolve: (String?, String) -> String? = NarrationModel.pocket.resolvedVoiceID(_:language:)
        let catalog: (String) -> [NarrationModel.CharacterVoice] = NarrationModel.pocket.characterVoiceCatalog(language:)
        XCTAssertNotNil(resolve(nil, "es"))
        XCTAssertFalse(catalog("es").isEmpty)
    }

    private func fixture(language: String = "es", name: String = "Victoria") throws -> Data {
        var header: [String: Any] = [:], body = Data()
        for layer in 0..<6 {
            let prefix = "transformer.layers.\(layer).self_attn/"
            let start = body.count
            // Two frames; distinguish K/V, frame, head and dimension to catch transposition errors.
            for i in 0..<4096 {
                var value = Float(i).bitPattern.littleEndian
                withUnsafeBytes(of: &value) { body.append(contentsOf: $0) }
            }
            header[prefix + "cache"] = ["dtype": "F32", "shape": [2,1,2,16,64], "data_offsets": [start, body.count]]
            let offset = body.count; var n = Int64(2).littleEndian
            withUnsafeBytes(of: &n) { body.append(contentsOf: $0) }
            header[prefix + "offset"] = ["dtype": "I64", "shape": [1], "data_offsets": [offset, body.count]]
        }
        let raw = try archive(header: header, body: body)
        let hash = try XCTUnwrap(PocketTTSCatalog.manifest(language: language).installedFiles.first { $0.path == "\(language)/model.safetensors" }?.sha256)
        return try PocketTTSImportedVoice.package(state: raw, metadata: .init(name: name, language: language,
            modelIdentity: PocketTTSCatalog.identity, modelSHA256: hash, attribution: "Synthetic test fixture"))
    }
    private func archive(header: [String: Any], body: Data) throws -> Data {
        var encoded = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while encoded.count % 8 != 0 { encoded.append(32) }
        var n = UInt64(encoded.count).littleEndian
        var result = withUnsafeBytes(of: &n) { Data($0) }; result.append(encoded); result.append(body)
        return result
    }
    private func mutate(_ data: Data, _ change: (inout [String: Any], inout Data) -> Void) throws -> Data {
        let n = data.withUnsafeBytes { Int(UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))) }
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: data.subdata(in: 8..<8+n)) as? [String: Any])
        var body = data.subdata(in: 8+n..<data.count)
        change(&header, &body)
        return try archive(header: header, body: body)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            PocketTTSVoiceRegistry.shared.replace([], in: url.appendingPathComponent("voices"))
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
    func testImportReopenDeduplicateAndRemove() async throws {
        let root = try folder(), file = root.appendingPathComponent("Victoria.libroxvoice")
        let bytes = try fixture(); try bytes.write(to: file)
        let store = PocketTTSVoiceStore(directory: root.appendingPathComponent("voices"))
        let voice = try await store.importVoice(from: file)
        XCTAssertLessThanOrEqual(voice.id.utf8.count, 64)
        XCTAssertEqual(voice.name, "Victoria"); XCTAssertEqual(voice.language, "es"); XCTAssertEqual(voice.referenceFrames, 2)
        let duplicate = try await store.importVoice(from: file)
        XCTAssertEqual(duplicate, voice)
        try FileManager.default.removeItem(at: file) // Installed file is owned by the store.
        // Simulate a new process: persisted files register with the normal catalog on reopen.
        PocketTTSVoiceRegistry.shared.replace([], in: root.appendingPathComponent("voices"))
        XCTAssertNil(PocketTTSCatalog.voice(id: voice.id))
        let reopened = try await PocketTTSVoiceStore(directory: root.appendingPathComponent("voices")).voices()
        XCTAssertEqual(reopened, [voice])
        XCTAssertEqual(PocketTTSCatalog.voice(id: voice.id)?.name, voice.name)
        XCTAssertEqual(NarrationModel.pocket.nativeVoices.first { $0.id == voice.id }?.engineVoiceID, voice.id)
        XCTAssertEqual(PocketTTSDeliveryCatalog.publishedStyles(voiceID: voice.id), [.original])
        XCTAssertEqual(try PocketTTSDeliveryCatalog.stateName(voiceID: voice.id, style: .original), voice.id)
        XCTAssertEqual(try PocketTTSDeliveryCatalog.narratorManifest(voiceID: voice.id, style: .original).installedFiles.map(\.sha256),
                       try PocketTTSBackend.platform.manifest(language: voice.language).installedFiles.map(\.sha256))
        let state = try voice.state()
        XCTAssertEqual(state.layers.count, 6)
        XCTAssertEqual(state.layers[0].key[64], 1024)
        XCTAssertEqual(state.layers[0].key[128], 64)
        XCTAssertEqual(state.layers[0].value[64], 3072)
        try await store.remove(voice)
        let remaining = try await store.voices(); XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(PocketTTSCatalog.voice(id: voice.id))
        XCTAssertThrowsError(try voice.state())
    }
    func testChangedFilesFailClosedAndReimportRepairs() async throws {
        let root = try folder(), source = root.appendingPathComponent("source.libroxvoice"), destination = root.appendingPathComponent("voices")
        try fixture().write(to: source)
        let store = PocketTTSVoiceStore(directory: destination), voice = try await store.importVoice(from: source)
        try fixture(name: "Changed").write(to: destination.appendingPathComponent(voice.sha256 + ".safetensors"))
        XCTAssertThrowsError(try voice.state())
        do { _ = try await store.voices(); XCTFail("Changed store must report an error") } catch {}
        let repaired = try await store.importVoice(from: source)
        XCTAssertEqual(repaired.id, voice.id); XCTAssertNoThrow(try repaired.state())
    }
    func testMalformedPackagesAreRejected() throws {
        let root = try folder(), file = root.appendingPathComponent("bad.libroxvoice"), valid = try fixture()
        let corrupt: [Data] = [Data(), Data(repeating: 255, count: 8), valid.dropLast(),
            try mutate(valid) { header, _ in header.removeValue(forKey: "__metadata__") },
            try mutate(valid) { header, _ in
                var meta = header["__metadata__"] as! [String: String]
                meta["librox.voice"] = meta["librox.voice"]!.replacingOccurrences(of: PocketTTSCatalog.identity, with: "other-model")
                header["__metadata__"] = meta
            },
            try mutate(valid) { header, _ in
                var t = header["transformer.layers.0.self_attn/cache"] as! [String: Any]
                t["shape"] = [2,1,Int.max,16,64]; header["transformer.layers.0.self_attn/cache"] = t
            },
            try mutate(valid) { _, body in body.replaceSubrange(0..<4, with: [0,0,192,127]) }, // NaN
            try mutate(valid) { header, _ in header["extra"] = header["transformer.layers.0.self_attn/offset"] },
            try mutate(valid) { header, _ in
                var t = header["transformer.layers.1.self_attn/offset"] as! [String: Any]
                t["data_offsets"] = (header["transformer.layers.0.self_attn/offset"] as! [String: Any])["data_offsets"]
                header["transformer.layers.1.self_attn/offset"] = t
            },
            try mutate(valid) { _, body in body.append(0) }]
        for (index, bytes) in corrupt.enumerated() {
            try bytes.write(to: file)
            XCTAssertThrowsError(try PocketTTSImportedVoice.inspect(at: file), "malformed case \(index)")
        }
    }
    func testCatalogPlanningCastAndMissingSelection() async throws {
        let root = try folder(), file = root.appendingPathComponent("Victoria.libroxvoice")
        try fixture().write(to: file); let voice = try PocketTTSImportedVoice.inspect(at: file)
        let model = NarrationModel.pocket
        let builtins = model.nativeVoices
        let store = PocketTTSVoiceStore(directory: root.appendingPathComponent("voices"))
        _ = try await store.importVoice(from: file)
        XCTAssertEqual(model.nativeVoices.count, builtins.count + 1)
        XCTAssertEqual(model.nativeVoices.filter { $0.id == voice.id }.count, 1)
        _ = try await store.importVoice(from: file)
        XCTAssertEqual(model.nativeVoices.count, builtins.count + 1)
        XCTAssertNil(model.resolvedVoiceID(voice.id, language: "en"))
        let pipeline = NarrationPipeline()
        let plan = try await pipeline.plan("Clara abrió la ventana. El mar estaba en calma.", model: .pocket,
            bookID: "test", chapterID: "1", narratorVoiceID: voice.id, language: "es",
            pocketDelivery: .init(narratorStyle: .happy))
        XCTAssertFalse(plan.units.isEmpty)
        XCTAssertTrue(plan.units.allSatisfy { $0.pocketChunking == .init() })
        XCTAssertTrue(plan.units.allSatisfy { $0.voiceID == voice.id && ($0.pocketDeliveryStyle ?? .original) == .original })
        let cast = try model.makeVoiceCast(bookID: "test", language: "es", narratorVoiceID: voice.id)
        let castPlan = try await pipeline.plan("Clara miró al mar.", model: .pocket, bookID: "test", chapterID: "2",
            narratorVoiceID: voice.id, language: "es", cast: cast, characterVoices: true)
        XCTAssertEqual(castPlan.cast?.narratorVoiceID, voice.id)
        try await store.remove(voice)
        do {
            _ = try await pipeline.plan("Hola.", model: .pocket, bookID: "test", chapterID: "3", narratorVoiceID: voice.id, language: "es")
            XCTFail("Missing custom voice must not become a preset")
        } catch {}
        let changed = try fixture(name: "Victoria 2"); try changed.write(to: file)
        let second = try PocketTTSImportedVoice.inspect(at: file)
        XCTAssertNotEqual(voice.id, second.id)
    }
    func testBackendsRejectUnsupportedDeliveryBeforeModelLoad() async throws {
        let root = try folder(), file = root.appendingPathComponent("Victoria.libroxvoice")
        try fixture().write(to: file)
        // Engines created before import must resolve the newly registered ID.
        let mlx = PocketTTSEngine(directory: root)
        let coreML = PocketTTSCoreMLEngine(directory: root)
        let store = PocketTTSVoiceStore(directory: root.appendingPathComponent("voices"))
        let voice = try await store.importVoice(from: file)
        do {
            _ = try await mlx.synthesize("Hola.", voiceID: voice.id, deliveryStyle: .happy)
            XCTFail("Unsupported style must fail")
        } catch PocketTTSImportedVoice.ImportError.unsupportedStyle {}
        do {
            _ = try await coreML.synthesize("Hola.", voiceID: voice.id, deliveryStyle: .happy)
            XCTFail("Unsupported style must fail")
        } catch PocketTTSImportedVoice.ImportError.unsupportedStyle {}
        try await store.remove(voice)
        do { _ = try await mlx.synthesize("Hola.", voiceID: voice.id); XCTFail("Removed voice") }
        catch PocketTTSError.invalidVoice {}
        do { _ = try await coreML.synthesize("Hola.", voiceID: voice.id); XCTFail("Removed voice") }
        catch PocketTTSError.invalidVoice {}
    }
    func testDisplayNameCannotSelectStockStylesOrReplaceStockVoice() async throws {
        let root = try folder(), file = root.appendingPathComponent("custom.libroxvoice")
        try fixture(name: "caro_davy").write(to: file)
        let stockID = "pocket-caro_davy-es-v1"
        let before = try await NarrationPipeline().plan("Hola.", model: .pocket, bookID: "test",
            chapterID: "1", narratorVoiceID: stockID, language: "es")
        let voice = try await PocketTTSVoiceStore(directory: root.appendingPathComponent("voices")).importVoice(from: file)
        XCTAssertFalse(PocketTTSDeliveryCatalog.offersStyles(voiceID: voice.id))
        XCTAssertEqual(PocketTTSCatalog.voice(id: voice.id)?.gender, .unknown)
        XCTAssertEqual(NarrationModel.pocket.resolvedVoiceID(stockID, language: "es"), stockID)
        XCTAssertEqual(NarrationModel.pocket.resolvedVoiceID(voice.id, language: "es"), voice.id)
        XCTAssertThrowsError(try PocketTTSDeliveryCatalog.stateName(voiceID: voice.id, style: .calm))
        let after = try await NarrationPipeline().plan("Hola.", model: .pocket, bookID: "test",
            chapterID: "1", narratorVoiceID: stockID, language: "es")
        XCTAssertEqual(before.units.first?.voiceID, after.units.first?.voiceID)
        XCTAssertEqual(before.units.first?.pocketChunking, after.units.first?.pocketChunking)
        XCTAssertEqual(NarrationModel.pocket.renderIdentity(for: before.units[0]),
                       NarrationModel.pocket.renderIdentity(for: after.units[0]))
    }

    func testDeletingUnusedVoiceDoesNotBreakExistingCast() async throws {
        let root = try folder(), file = root.appendingPathComponent("custom.libroxvoice")
        try fixture().write(to: file)
        let store = PocketTTSVoiceStore(directory: root.appendingPathComponent("voices"))
        let voice = try await store.importVoice(from: file)
        let model = NarrationModel.pocket, narrator = "pocket-caro_davy-es-v1"
        let cast = try model.makeVoiceCast(bookID: "test", language: "es", narratorVoiceID: narrator)
        XCTAssertTrue(cast.voicePool.contains(voice.id))
        try await store.remove(voice)
        let plan = try await NarrationPipeline().plan("Clara abrió la ventana.", model: model,
            bookID: "test", chapterID: "1", narratorVoiceID: narrator, language: "es", cast: cast, characterVoices: true)
        XCTAssertEqual(plan.narratorVoiceID, narrator)
        XCTAssertFalse(try XCTUnwrap(plan.cast).voicePool.contains(voice.id))
        XCTAssertFalse(try model.expandingVoiceCatalog(in: cast).voicePool.contains(voice.id))
    }

    func testCustomCharacterAssignmentSurvivesCastRestore() async throws {
        let root = try folder(), file = root.appendingPathComponent("Victoria.libroxvoice")
        try fixture().write(to: file)
        let voice = try await PocketTTSVoiceStore(directory: root.appendingPathComponent("voices")).importVoice(from: file), model = NarrationModel.pocket
        let narrator = try XCTUnwrap(model.nativeVoices.first { $0.language == "es" }?.id)
        let initial = try model.makeVoiceCast(bookID: "test", language: "es", narratorVoiceID: narrator)
        let text = "«Buenos días», dijo Clara. Clara abrió la ventana."
        let pipeline = NarrationPipeline()
        let discovered = try await pipeline.plan(text, model: model, bookID: "test", chapterID: "1",
            narratorVoiceID: narrator, language: "es", cast: initial, characterVoices: true)
        var cast = try XCTUnwrap(discovered.cast)
        let character = try XCTUnwrap(cast.characters.first)
        try cast.setVoice(voice.id, for: character.id)
        let restored = try BookVoiceCast.restore(cast.encoded(), bookID: "test")
        let final = try await pipeline.plan(text, model: model, bookID: "test", chapterID: "2",
            narratorVoiceID: narrator, language: "es", cast: restored, characterVoices: true)
        XCTAssertTrue(final.units.contains { $0.role == .dialogue && $0.voiceID == voice.id })
        XCTAssertEqual(final.cast?.characterVoices[character.id], voice.id)
        try await PocketTTSVoiceStore(directory: root.appendingPathComponent("voices")).remove(voice)
        do {
            _ = try await pipeline.plan(text, model: model, bookID: "test", chapterID: "3",
                narratorVoiceID: narrator, language: "es", cast: restored, characterVoices: true)
            XCTFail("A selected deleted voice must not be silently replaced")
        } catch NarrationPipeline.PlanningError.invalidVoice {}
    }

}
