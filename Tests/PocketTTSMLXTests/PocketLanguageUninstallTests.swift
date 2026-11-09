import Foundation
import Testing
import LibroxTTS
import KokoroCatalog
import PocketTTSMLX

/// Lays out manifest-sized (sparse) files so presence checks pass without
/// shipping weights. Hash validation is covered by the POCKET_ASSETS test.
private func fakeMaxInstall(languages: [String], styles: Bool = true) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("max-uninstall-" + UUID().uuidString, isDirectory: true)
    for language in languages {
        var files = try PocketTTSCatalog.manifest(language: language).installedFiles
        if styles { files += try PocketTTSDeliveryCatalog.manifest(language: language).installedFiles }
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.size)); try handle.close()
        }
    }
    // Host receipts sit beside the language folders and are not the SDK's to remove.
    try Data("{}".utf8).write(to: root.appendingPathComponent("libros-manifest.json"))
    return root
}

private func isPresent(_ language: String, in directory: URL) -> Bool {
    NarrationAssets.isPrepared(directory, model: .pocket, language: language)
}

@Test func everyMaxLanguageFileLivesUnderItsOwnFolder() throws {
    // Per-language uninstall removes <lang>/ only; nothing may be shared at the top level.
    for language in PocketTTSCatalog.languages {
        let files = try PocketTTSCatalog.manifest(language: language).installedFiles
            + PocketTTSDeliveryCatalog.manifest(language: language).installedFiles
        #expect(files.allSatisfy { $0.path.hasPrefix(language + "/") })
    }
}

@Test func uninstallingOneMaxLanguageLeavesTheOthersInstalled() throws {
    let root = try fakeMaxInstall(languages: ["en", "es", "fr"])
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = NarrationAssets.installedPocketBytes(language: "es", in: root)
    let base = try PocketTTSCatalog.manifest(language: "es").installedFiles.reduce(Int64(0)) { $0 + $1.size }
    let delivery = try PocketTTSDeliveryCatalog.manifest(language: "es").installedFiles.reduce(Int64(0)) { $0 + $1.size }
    #expect(expected == base + delivery)

    let freed = try NarrationAssets.uninstallPocketLanguage("es", in: root)

    #expect(freed == expected)
    #expect(!isPresent("es", in: root))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("es").path))
    #expect(NarrationAssets.installedPocketBytes(language: "es", in: root) == 0)
    #expect(isPresent("en", in: root) && isPresent("fr", in: root))
    #expect(NarrationAssets.installedPocketLanguages(in: root) == ["en", "fr"])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("libros-manifest.json").path))
    // No staging folder is left behind to count toward Storage.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty)
}

@Test func uninstallingAMaxLanguageTwiceIsHarmless() throws {
    let root = try fakeMaxInstall(languages: ["en", "es"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try NarrationAssets.uninstallPocketLanguage("es", in: root) > 0)
    #expect(try NarrationAssets.uninstallPocketLanguage("es", in: root) == 0)
    #expect(try NarrationAssets.uninstallPocketLanguage("de", in: root) == 0)
    #expect(isPresent("en", in: root))
}

@Test func uninstallRejectsLanguagesOutsideTheCatalog() throws {
    let root = try fakeMaxInstall(languages: ["en"])
    defer { try? FileManager.default.removeItem(at: root) }
    for bad in ["", "..", "../en", "en/embeddings", "ja", "EN"] {
        #expect(throws: PocketTTSError.unsupportedLanguage) { try NarrationAssets.uninstallPocketLanguage(bad, in: root) }
    }
    #expect(isPresent("en", in: root))
}

@Test func uninstallSweepsAnInterruptedEarlierUninstall() throws {
    let root = try fakeMaxInstall(languages: ["en", "es"])
    defer { try? FileManager.default.removeItem(at: root) }
    let stale = root.appendingPathComponent(".uninstalling-fr-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try Data(count: 16).write(to: stale.appendingPathComponent("model.safetensors"))
    _ = try NarrationAssets.uninstallPocketLanguage("es", in: root)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(isPresent("en", in: root))
}

@Test func rendererWithNothingLoadedUninstallsAndReportsNoLanguage() async throws {
    let root = try fakeMaxInstall(languages: ["en", "es"], styles: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let renderer = NarrationRenderer(compactDirectory: root, harmonicSource: nil)
    #expect(await renderer.loadedPocketLanguage == nil)
    #expect(try await renderer.uninstallPocketLanguage("es", in: root) > 0)
    #expect(!isPresent("es", in: root) && isPresent("en", in: root))
}

/// Real weights: POCKET_ASSETS must hold verified en/ and es/ packs. The test
/// clones them (APFS copy-on-write) so the source is never modified.
@Test(.enabled(if: ProcessInfo.processInfo.environment["POCKET_ASSETS"] != nil))
func uninstallingTheLoadedLanguageUnloadsItAndOtherLanguagesStillRender() async throws {
    let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POCKET_ASSETS"]!)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("max-uninstall-real-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for language in ["en", "es"] {
        try FileManager.default.copyItem(at: source.appendingPathComponent(language), to: root.appendingPathComponent(language))
    }
    PocketTestMetal.configure()
    let pipeline = NarrationPipeline()
    func unit(_ text: String, _ language: String) async throws -> BookNarrationUnit {
        let plan = try await pipeline.plan(text, model: .pocket, bookID: "uninstall", chapterID: language,
            narratorVoiceID: "pocket-caro_davy-\(language)-v1", language: language)
        return try #require(plan.units.first)
    }
    let renderer = NarrationRenderer(compactDirectory: root, harmonicSource: nil)
    try await renderer.load(.pocket, directory: root, executionContext: .foreground)
    let spanish = try await unit("Hola, esto es una prueba.", "es")
    #expect(try await !renderer.render(spanish).isEmpty)
    #expect(await renderer.loadedPocketLanguage == "es")

    #expect(try await renderer.uninstallPocketLanguage("es", in: root) > 0)
    #expect(await renderer.loadedPocketLanguage == nil)
    await #expect(throws: (any Error).self) { try await renderer.render(spanish) }

    try PocketTTSCatalog.validate(in: root, language: "en")
    let english = try await unit("Hello, this is a test.", "en")
    #expect(try await !renderer.render(english).isEmpty)
    #expect(await renderer.loadedPocketLanguage == "en")
    await renderer.unload()
}
