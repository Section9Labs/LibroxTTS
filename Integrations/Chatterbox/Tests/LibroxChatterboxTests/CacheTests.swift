import Testing
@testable import LibroxChatterbox

@Test func cacheSeparatesArtifactsConditioningAndExpression() throws {
    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
    let base = try ChatterboxRequest(text: "Hello.", language: "en", seed: 42)
    let key = try base.cacheKey(modelManifestSHA256: a, conditioningSHA256: a)
    #expect(try key == base.cacheKey(modelManifestSHA256: a, conditioningSHA256: a))
    #expect(try key != base.cacheKey(modelManifestSHA256: b, conditioningSHA256: a))
    #expect(try key != base.cacheKey(modelManifestSHA256: a, conditioningSHA256: b))
    #expect(try key != base.cacheKey(modelManifestSHA256: a, conditioningSHA256: a, rendererProfile: "automatic:padded1024"))
    for request in [
        try ChatterboxRequest(text: "Hello.", language: "en", exaggeration: 0.8, seed: 42),
        try ChatterboxRequest(text: "Hello.", language: "en", guidance: 0.8, seed: 42),
        try ChatterboxRequest(text: "Hello.", language: "en", seed: 43),
        try ChatterboxRequest(text: "Hello.", language: "es", seed: 42),
        try ChatterboxRequest(text: "Hello!", language: "en", seed: 42),
    ] {
        #expect(try key != request.cacheKey(modelManifestSHA256: a, conditioningSHA256: a))
    }
    #expect(throws: ChatterboxNarrationError.invalidOptions) {
        try base.cacheKey(modelManifestSHA256: "unpinned", conditioningSHA256: a)
    }
}
