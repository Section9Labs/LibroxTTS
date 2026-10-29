import Foundation
import MLX

/// Non-audio causal diagnostic using only the pinned public oracle. This never
/// clears a renderer, accepts book text, or supplies a production KV fallback.
/// The caller must cancel/join/unload narration before starting this exclusive
/// diagnostic. It retains every normal resource guard and joins on cancellation.
public enum ChatterboxQ8FixedFixtureDiagnostic {
    public static let cpuPrefillCacheSHA256 = "59e0cbdab848feb2977359ac8a8e90e0bd0dc54a0fafa312f86fd5f7c7d01f6f"
    public static let cpuPrefillCacheBytes = 22_862_030
    public enum Failure: Error { case configuration, identity, fixture, busy }
    private actor Lease {
        var occupied = false
        func acquire() throws {
            try Task.checkCancellation()
            guard !occupied else { throw Failure.busy }
            occupied = true
        }
        func release() { occupied = false }
    }
    private static let lease = Lease()
    public struct Configuration: Sendable {
        public let weightsFile: URL
        public let oracleFile: URL
        public let cpuPrefillCacheFile: URL
        public init(weightsFile: URL, oracleFile: URL, cpuPrefillCacheFile: URL) {
            self.weightsFile = weightsFile; self.oracleFile = oracleFile
            self.cpuPrefillCacheFile = cpuPrefillCacheFile
        }
    }
    public struct Lane: Sendable, Codable {
        public let actualTopID: Int
        public let expectedTopID: Int
        public let expectedSecondID: Int
        public let expectedMargin: Float
        public let actualMarginBetweenExpectedLeaders: Float
    }
    public struct Comparison: Sendable, Codable {
        public let stage: String
        public let maximumAbsoluteError: Float
        public let relativeL2: Double
        public let lanes: [Lane]
        public let passesOriginalCriteria: Bool
    }
    public struct Arm: Sendable, Codable {
        public let name: String
        public let prefillComputation: String
        public let comparisons: [Comparison]
    }
    public struct Report: Sendable, Codable {
        public let diagnosticOnly: Bool
        public let decoderProfile: String
        public let weightsSHA256: String
        public let oracleSHA256: String
        public let cpuPrefillCacheSHA256: String
        public let arms: [Arm]
        public let nativeRestoreDecodeBitIdentical: Bool
        public let nativeRestoreDecodeExactByStage: [Bool]
        public let wallSeconds: Double
        public let finalMemory: ChatterboxMLXRenderer.MemorySnapshot
        public let memoryScope: String
    }

    public static func run(_ configuration: Configuration) async throws -> Report {
        try await lease.acquire()
        let result: Report
        do {
            let worker = Task.detached(priority: .userInitiated) { try runSynchronously(configuration) }
            result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
        } catch {
            await lease.release()
            throw error
        }
        await lease.release()
        try Task.checkCancellation()
        return result
    }

    private struct ArmResult {
        let report: Arm
        let decodeOutputs: [[Float]]
    }
    private enum CacheSource: String, CaseIterable {
        case native, nativeSnapshotRestored, cpuPrefillRestored
    }
    private static func runSynchronously(_ c: Configuration) throws -> Report {
        let began = Date()
        let profile = ChatterboxMLXRenderer.DecoderProfile.q8CanonicalHalfV2
        guard ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0"
        else { throw Failure.configuration }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: 3 * 1_024 * 1_024 * 1_024)
        guard try c.cpuPrefillCacheFile.resourceValues(forKeys: [.fileSizeKey]).fileSize == cpuPrefillCacheBytes,
            try ChatterboxMLXRenderer.digest(c.weightsFile) == profile.weightsSHA256,
            try ChatterboxMLXRenderer.digest(c.oracleFile) == profile.oracleSHA256,
            try ChatterboxMLXRenderer.digest(c.cpuPrefillCacheFile) == cpuPrefillCacheSHA256
        else { throw Failure.identity }
        return try Device.withDefaultDevice(.gpu) {
            defer { ChatterboxMLXRenderer.trimUnusedMemory() }
            let fixture = try loadArrays(url: c.oracleFile)
            let referenceCache = try loadArrays(url: c.cpuPrefillCacheFile)
            let required = Set((0..<30).flatMap { ["es.prefill.layer.\($0).keys", "es.prefill.layer.\($0).values"] })
            guard referenceCache.count == 60, Set(referenceCache.keys) == required else { throw Failure.fixture }
            for value in referenceCache.values {
                try ChatterboxMLXRenderer.healthy()
                guard value.shape == [2, 16, 93, 64], value.dtype == .float16,
                    all(isFinite(value)).item(Bool.self) else { throw Failure.fixture }
            }
            let model = try Q8DecoderWeights.load(from: c.weightsFile, canonicalHalf: true)
            var results: [ArmResult] = []
            for source in CacheSource.allCases {
                try ChatterboxMLXRenderer.healthy()
                results.append(try runArm(source, model: model, fixture: fixture, cpuCache: referenceCache))
                ChatterboxMLXRenderer.trimUnusedMemory()
            }
            let exact = zip(results[0].decodeOutputs, results[1].decodeOutputs).map { a, b in
                a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
            }
            guard exact.count == 3 else { throw Failure.fixture }
            return Report(diagnosticOnly: true, decoderProfile: profile.rawValue,
                weightsSHA256: profile.weightsSHA256, oracleSHA256: profile.oracleSHA256,
                cpuPrefillCacheSHA256: cpuPrefillCacheSHA256, arms: results.map(\.report),
                nativeRestoreDecodeBitIdentical: exact.allSatisfy { $0 },
                nativeRestoreDecodeExactByStage: exact,
                wallSeconds: Date().timeIntervalSince(began), finalMemory: ChatterboxMLXRenderer.memorySnapshot(),
                memoryScope: "final snapshot; peakBytes is process-global historical MLX peak, not isolated diagnostic peak")
        }
    }

    @inline(never)
    private static func runArm(_ source: CacheSource, model: SpeechDecoder,
                               fixture: [String: MLXArray], cpuCache: [String: MLXArray]) throws -> ArmResult {
        // Reproduce the normal gate's preceding English work, then release its
        // independent caches before the Spanish intervention.
        do {
            let english = (0..<30).map { _ in KVCache() }
            for step in 0...8 {
                try ChatterboxMLXRenderer.healthy()
                let stem = step == 0 ? "en.prefill" : "en.decode.\(step - 1)"
                guard let input = fixture[stem + ".input"] else { throw Failure.fixture }
                eval(model.logits(input, cache: english))
            }
        }
        var caches = (0..<30).map { _ in KVCache() }
        var comparisons: [Comparison] = [], outputs: [[Float]] = []
        for step in 0...3 {
            try ChatterboxMLXRenderer.healthy()
            let stem = step == 0 ? "es.prefill" : "es.decode.\(step - 1)"
            guard let input = fixture[stem + ".input"], let expected = fixture[stem + ".logits"]
            else { throw Failure.fixture }
            let logits = model.logits(input, cache: caches); eval(logits)
            let actual = logits.asArray(Float.self), target = expected.asArray(Float.self)
            comparisons.append(try compare(actual, target, stage: stem))
            if step > 0 { outputs.append(actual) }
            if step == 0, source != .native {
                if source == .nativeSnapshotRestored {
                    let bytes = try caches.map {
                        try ChatterboxMLXRenderer.healthy()
                        return try $0.fixedFixtureSnapshot()
                    }
                    caches = try bytes.map {
                        try ChatterboxMLXRenderer.healthy()
                        return try KVCache.restoringFixedFixture(keys: MLXArray($0.keys, [2, 16, 93, 64]),
                            values: MLXArray($0.values, [2, 16, 93, 64]))
                    }
                } else {
                    caches = try (0..<30).map { index in
                        try ChatterboxMLXRenderer.healthy()
                        guard let k = cpuCache["es.prefill.layer.\(index).keys"],
                            let v = cpuCache["es.prefill.layer.\(index).values"] else { throw Failure.fixture }
                        return try KVCache.restoringFixedFixture(keys: k, values: v)
                    }
                }
            }
        }
        return ArmResult(report: Arm(name: source.rawValue,
            prefillComputation: "nativeV2; cache substitution affects decode only", comparisons: comparisons),
            decodeOutputs: outputs)
    }

    private static func compare(_ a: [Float], _ b: [Float], stage: String) throws -> Comparison {
        guard a.count == 16_388, b.count == a.count,
            a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { throw Failure.fixture }
        var maximum: Float = 0, squared = 0.0, norm = 0.0
        for (x, y) in zip(a, b) {
            maximum = max(maximum, abs(x - y)); squared += pow(Double(x - y), 2); norm += pow(Double(y), 2)
        }
        let lanes = (0..<2).map { lane -> Lane in
            let range = (lane * 8194)..<((lane + 1) * 8194)
            let leaders = range.sorted { b[$0] > b[$1] }
            let actual = range.max { a[$0] < a[$1] }!
            return Lane(actualTopID: actual - lane * 8194, expectedTopID: leaders[0] - lane * 8194,
                expectedSecondID: leaders[1] - lane * 8194,
                expectedMargin: b[leaders[0]] - b[leaders[1]],
                actualMarginBetweenExpectedLeaders: a[leaders[0]] - a[leaders[1]])
        }
        let relative = sqrt(squared / max(norm, 1e-30))
        return Comparison(stage: stage, maximumAbsoluteError: maximum, relativeL2: relative, lanes: lanes,
            passesOriginalCriteria: maximum <= 0.05 && relative <= 0.002 && lanes.allSatisfy { $0.actualTopID == $0.expectedTopID })
    }
}
