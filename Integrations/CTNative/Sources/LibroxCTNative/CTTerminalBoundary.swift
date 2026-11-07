import Foundation

/// Structural end-of-utterance selector. Never removes tokens or selects words.
struct CTTerminalBoundary {
    static let revision = "second-style-terminal-selector-v1"
    let tensor: CTTensor
    let protectedIndices: [Int]
    let usedFallback: Bool

    init(normalized: String, language: String, allOnes: Bool = false) throws {
        let scalars = Array(normalized.unicodeScalars)
        let opening = "<\(language)>", closing = "</\(language)>"
        let valid = ["en", "es"].contains(language) && normalized.hasPrefix(opening)
            && normalized.hasSuffix(closing) && scalars.count >= opening.unicodeScalars.count + closing.unicodeScalars.count
        usedFallback = !valid
        var values = [Float](repeating: 1, count: scalars.count)
        if valid && !allOnes {
            let end = scalars.count - closing.unicodeScalars.count
            var start = end
            let boundary = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
            while start > opening.unicodeScalars.count && boundary.contains(scalars[start - 1]) { start -= 1 }
            for index in start..<scalars.count { values[index] = 0 }
        }
        protectedIndices = values.indices.filter { values[$0] == 0 }
        tensor = try CTTensor(values, shape: [1, scalars.count, 1])
    }
}
