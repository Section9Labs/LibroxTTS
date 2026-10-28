import Foundation

/// Token sampler: repetition penalty → temperature → top-p (nucleus), or greedy.
struct Sampler {
    private let options: GenerationOptions
    private var rng: SystemRandomNumberGenerator
    private var seeded: SeededGenerator?

    init(options: GenerationOptions) {
        self.options = options
        self.rng = SystemRandomNumberGenerator()
        self.seeded = options.seed.map(SeededGenerator.init)
    }

    private mutating func uniform() -> Float {
        if seeded != nil {
            return seeded!.nextUnit()
        }
        return Float.random(in: 0..<1, using: &rng)
    }

    mutating func sample(logits rawLogits: [Float], previous: [Int], minTokensReached: Bool) -> Int {
        var logits = rawLogits

        // Repetition penalty over the recent window.
        if options.repetitionPenalty != 1.0, !previous.isEmpty {
            let window = previous.suffix(options.repetitionWindow)
            for t in Set(window) where t >= 0 && t < logits.count {
                let l = logits[t]
                logits[t] = l > 0 ? l / options.repetitionPenalty : l * options.repetitionPenalty
            }
        }

        // Forbid the stop token until the minimum length is reached.
        if !minTokensReached, Constants.speechStopToken < logits.count {
            logits[Constants.speechStopToken] = -Float.greatestFiniteMagnitude
        }

        if options.greedy {
            return argmax(logits)
        }

        // Temperature.
        let temp = max(options.temperature, 1e-5)
        if temp != 1.0 {
            for i in logits.indices { logits[i] /= temp }
        }

        // Softmax.
        let maxLogit = logits.max() ?? 0
        var probs = logits.map { expf($0 - maxLogit) }
        let sum = probs.reduce(0, +)
        if sum > 0 { for i in probs.indices { probs[i] /= sum } }

        // Rank by probability, then filter. Two modes:
        //  - turbo: top-k then top-p (nucleus).
        //  - multilingual (`minP > 0`): min-p floor then top-p, no top-k — matches
        //    `T3.inference`'s `MinPLogitsWarper` → `TopPLogitsWarper` order. min-p
        //    keeps tokens with `prob ≥ minP · maxProb` (at least the top token).
        var order = probs.indices.sorted { probs[$0] > probs[$1] }
        if options.minP > 0 {
            let maxProb = order.first.map { probs[$0] } ?? 0
            let threshold = options.minP * maxProb
            let kept = order.filter { probs[$0] >= threshold }
            order = kept.isEmpty ? Array(order.prefix(1)) : kept
        } else if options.topK > 0, order.count > options.topK {
            order = Array(order.prefix(options.topK))
        }
        var cumulative: Float = 0
        var keep: [Int] = []
        for idx in order {
            keep.append(idx)
            cumulative += probs[idx]
            if cumulative >= options.topP { break }
        }

        // Sample within the kept set, renormalized.
        let keepSum = keep.reduce(Float(0)) { $0 + probs[$1] }
        guard keepSum > 0 else { return argmax(rawLogits) }
        var r = uniform() * keepSum
        for idx in keep {
            r -= probs[idx]
            if r <= 0 { return idx }
        }
        return keep.last ?? argmax(rawLogits)
    }

    private func argmax(_ values: [Float]) -> Int {
        var best = 0
        var bestVal = -Float.greatestFiniteMagnitude
        for (i, v) in values.enumerated() where v > bestVal { bestVal = v; best = i }
        return best
    }
}

/// Small deterministic PRNG (SplitMix64) for reproducible sampling.
private struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }
}
