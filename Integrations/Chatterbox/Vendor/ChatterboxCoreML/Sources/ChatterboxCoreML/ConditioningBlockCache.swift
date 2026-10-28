import Synchronization

/// One immutable T3 voice prefix per loaded runner. The runner's embedding and
/// projection tables never change, so only reference content and exaggeration
/// participate in the key. Exact float bits distinguish signed zero and NaNs.
///
/// Holding the mutex through construction makes a concurrent first request
/// single-flight. No asynchronous work, MLState, or Core ML prediction occurs
/// under this lock. Returned arrays use Swift copy-on-write value semantics.
final class ConditioningBlockCache: Sendable {
    struct Key: Equatable, Sendable {
        let speakerBits: [UInt32]
        let promptTokens: [Int32]
        let exaggerationBits: UInt32

        init(speaker: [Float], promptTokens: [Int32], exaggeration: Float) {
            speakerBits = speaker.map(\.bitPattern)
            self.promptTokens = promptTokens
            exaggerationBits = exaggeration.bitPattern
        }
    }

    private struct Entry: Sendable {
        let key: Key
        let values: [Float]
    }

    private let entry = Mutex<Entry?>(nil)

    func value(for key: Key, build: () -> [Float]) -> (values: [Float], hit: Bool) {
        entry.withLock { stored in
            if let stored, stored.key == key { return (stored.values, true) }
            let values = build()
            stored = Entry(key: key, values: values)
            return (values, false)
        }
    }
}
