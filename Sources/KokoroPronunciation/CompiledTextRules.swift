import Foundation
import Synchronization

/// Immutable syntax rules only, never source text or normalized readings.
/// Normalization can recurse (currency/counts) and can run on independent actors:
/// release the lock before compilation, matching, or invoking a replacement.
enum CompiledTextRules {
    private static let expressions = Mutex<[String: NSRegularExpression]>([:])
    private static let capacity = 128

    static func expression(_ pattern: String) -> NSRegularExpression? {
        if let cached = expressions.withLock({ $0[pattern] }) { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        return expressions.withLock { values in
            if let cached = values[pattern] { return cached }
            // A finite language-rule set normally stays below this bound. Keep
            // memory bounded if more rule families are added in future releases.
            if values.count >= capacity { values.removeAll(keepingCapacity: true) }
            values[pattern] = compiled
            return compiled
        }
    }
}
