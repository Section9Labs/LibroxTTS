import Synchronization

/// Shares immutable resources only while clients own them. Failed construction
/// is never cached. Construction and publication are serialized once per miss.
final class WeakResourceCache<Key: Hashable & Sendable, Value: AnyObject & Sendable>: Sendable {
    private struct Reference: Sendable { weak var value: Value? }
    private let references = Mutex<[Key: Reference]>([:])
    func value(for key: Key, load: () throws -> Value) rethrows -> Value {
        try references.withLock { slots in
            if let value = slots[key]?.value { return value }
            let value = try load()
            slots[key] = Reference(value: value)
            return value
        }
    }
}
