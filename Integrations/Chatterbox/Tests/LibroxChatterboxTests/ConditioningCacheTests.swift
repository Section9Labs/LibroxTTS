import Foundation
import Synchronization
import Testing
@testable import ChatterboxCoreML

@Test func conditioningCacheUsesExactContentAndIsBounded() {
    let cache = ConditioningBlockCache()
    var builds = 0
    func get(_ key: ConditioningBlockCache.Key) -> (values: [Float], hit: Bool) {
        cache.value(for: key) { builds += 1; return [Float(builds)] }
    }
    let first = ConditioningBlockCache.Key(speaker: [0, 1], promptTokens: [1, 2], exaggeration: 0.5)
    #expect(!get(first).hit)
    #expect(get(first).values == [1])
    #expect(builds == 1)
    #expect(!get(.init(speaker: [-0.0, 1], promptTokens: [1, 2], exaggeration: 0.5)).hit)
    #expect(!get(.init(speaker: [-0.0, 1], promptTokens: [2, 1], exaggeration: 0.5)).hit)
    #expect(!get(.init(speaker: [-0.0, 1], promptTokens: [2, 1], exaggeration: 0.6)).hit)
    // Returning to the first voice rebuilds: there is no hidden unbounded map.
    #expect(!get(first).hit)
    #expect(builds == 5)
    // Mutating a caller's array cannot corrupt the retained value.
    var returned = get(first).values
    returned[0] = -1
    #expect(get(first).values == [5])
}

@Test func conditioningCacheConcurrentMissBuildsOnce() {
    let cache = ConditioningBlockCache()
    let builds = Mutex(0)
    let outputs = Mutex<[[Float]]>([])
    let key = ConditioningBlockCache.Key(speaker: [0.25], promptTokens: [42], exaggeration: 0.5)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
        let result = cache.value(for: key) {
            builds.withLock { $0 += 1 }
            return [Float(bitPattern: 0x3f123456)]
        }
        outputs.withLock { $0.append(result.values) }
    }
    #expect(builds.withLock { $0 } == 1)
    #expect(outputs.withLock { $0.count == 32 && $0.allSatisfy { $0[0].bitPattern == 0x3f123456 } })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHATTERBOX_HOST_BENCH_MODELS"] != nil))
func conditioningCacheRealAssemblyParityAndTiming() throws {
    let environment = ProcessInfo.processInfo.environment
    let directory = URL(fileURLWithPath: try #require(environment["CHATTERBOX_HOST_BENCH_MODELS"]))
    let voice = URL(fileURLWithPath: try #require(environment["CHATTERBOX_HOST_BENCH_VOICE"]))
    let report = URL(fileURLWithPath: try #require(environment["CHATTERBOX_HOST_BENCH_REPORT"]))
    let textEmb = try EmbeddingTable(contentsOf: directory.appendingPathComponent("text_emb.npy"), name: "text_emb")
    let textPos = try EmbeddingTable(contentsOf: directory.appendingPathComponent("text_pos_emb.npy"), name: "text_pos")
    let speechEmb = try SpeechEmbedding(contentsOf: directory.appendingPathComponent("speech_emb.npy"))
    let speechPos = try EmbeddingTable(contentsOf: directory.appendingPathComponent("speech_pos_emb.npy"), name: "speech_pos")
    let builder = try CondBlockBuilder(dir: directory)
    let conds = try Conditionals(contentsOf: voice)
    func assembler() -> MTLPrefillAssembler {
        MTLPrefillAssembler(textEmb: textEmb, textPosEmb: textPos, speechEmb: speechEmb,
                            speechPosEmb: speechPos, condBuilder: builder)
    }
    func timed(_ body: () -> MTLPrefillAssembler.Assembled) -> (MTLPrefillAssembler.Assembled, Double) {
        let start = ContinuousClock.now
        let result = body()
        let elapsed = start.duration(to: .now).components
        return (result, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    let retained = assembler()
    let baseline = retained.assemble(textTokens: [1, 2, 3], conds: conds, exaggeration: 0.5)
    #expect(!baseline.conditioningCacheHit)
    var cold: [Double] = [], warm: [Double] = []
    for _ in 0..<5 {
        let (uncached, coldTime) = timed { assembler().assemble(textTokens: [1, 2, 3], conds: conds, exaggeration: 0.5) }
        let (cached, warmTime) = timed { retained.assemble(textTokens: [1, 2, 3], conds: conds, exaggeration: 0.5) }
        #expect(!uncached.conditioningCacheHit && cached.conditioningCacheHit)
        #expect(uncached.inputsEmbeds.map(\.bitPattern) == cached.inputsEmbeds.map(\.bitPattern))
        #expect(uncached.positionIds == cached.positionIds)
        #expect(uncached.logitsSelectMask == cached.logitsSelectMask)
        cold.append(coldTime); warm.append(warmTime)
    }
    let result: [String: Any] = ["evidence": "optimized host assembly only; not device narration throughput",
        "uncachedSeconds": cold, "cachedSeconds": warm,
        "uncachedMedianSeconds": cold.sorted()[cold.count / 2],
        "cachedMedianSeconds": warm.sorted()[warm.count / 2], "bitExact": true,
        "referenceTokens": conds.condPromptSpeechTokens.count]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
}
