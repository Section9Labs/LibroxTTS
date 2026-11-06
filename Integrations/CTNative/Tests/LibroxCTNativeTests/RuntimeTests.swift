import Foundation
import Testing
import LibroxCTNative

@Test func assetValidationRejectsSameSizeCorruption() throws {
    let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try #require(CTAssets.manifest().files.first)
    let file = root.appendingPathComponent(first.path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0, count: first.bytes).write(to: file)
    #expect(throws: CTError.self) { try CTAssets.validate(root) }
}

/// Opt-in real graph test; ordinary package tests need no 434 MB model bundle.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_TEST_ASSETS"] != nil))
func nativeCancellationAndReloadRetireTheOldRequest() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["CT_TEST_ASSETS"])
    let engine = CTEngine(directory: URL(fileURLWithPath: path), backend: .coreMLCPU)
    try await engine.load()
    let request = Task.detached { try await engine.synthesize("She waited. He came back.", language: "en") }
    try await Task.sleep(for: .milliseconds(50))
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    await engine.unload()
    await #expect(throws: CTError.self) { try await engine.synthesize("He returned.", language: "en") }
    try await engine.load()
    let recovered = try await engine.synthesize("Él volvió. Ella sonrió.", language: "es")
    #expect(!recovered.samples.isEmpty)
    #expect(recovered.samples.allSatisfy { $0.isFinite })
    await engine.unload()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_TEST_ASSETS"] != nil))
func arbitraryPassagesAndBackendChangesStayBounded() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["CT_TEST_ASSETS"])
    let engine = CTEngine(directory: URL(fileURLWithPath: path), backend: .coreMLGPUHeavy)
    try await engine.load()
    let cases = [("I.", "en"), ("Sí. Ven aquí.", "es"),
                 ("Wait—did you hear that? No, she whispered. The house was quiet again, but neither of them moved.", "en"),
                 ("Recordaba los árboles en verano, el agua bajo el puente y la promesa que habían hecho antes de que saliera el último tren.", "es")]
    for backend in [CTEngine.Backend.coreMLGPUHeavy, .coreMLCPU, .coreMLGPUHeavy] {
        try await engine.setBackend(backend)
        for (text, language) in cases {
            let result = try await engine.synthesize(text, language: language)
            #expect(result.trace.isEmpty)
            #expect(result.samples.count > 0 && result.samples.count <= 431 * 3072)
            #expect(result.samples.allSatisfy { $0.isFinite })
        }
    }
    await engine.unload()
}
