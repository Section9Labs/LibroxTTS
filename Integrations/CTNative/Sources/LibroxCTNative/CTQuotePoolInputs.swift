import Foundation

/// Private round-03 style-pooling input. The encoder still reads every context
/// token with its original content mask. This mask only selects global queries.
struct CTQuotePoolInputs {
    static let revision = "quote-excluded-context-pool-1"
    let tensor: CTTensor
    let excludedCount: Int
    let lexicalOutsideCount: Int
    let usedFallback: Bool

    init(binding: CTTextContext.Binding, allOnesControl: Bool = false) throws {
        let context = Array(binding.normalizedContext.unicodeScalars)
        let spoken = Array(binding.normalizedSpoken.unicodeScalars)
        let indices = binding.gatherIndices
        guard (8...512).contains(context.count), indices.count == spoken.count,
              indices.allSatisfy({ context.indices.contains($0) }),
              Set(indices).count == indices.count, indices == indices.sorted(),
              indices.map({ context[$0] }) == spoken,
              binding.normalizedContext.hasPrefix("<\(binding.language)>"),
              binding.normalizedContext.hasSuffix("</\(binding.language)>") else {
            throw CTError.invalidTensor("quote pool binding")
        }
        let excluded = Set(indices)
        let lexical = CharacterSet.letters.union(.decimalDigits)
        lexicalOutsideCount = context.indices.filter { !excluded.contains($0) && lexical.contains(context[$0]) }.count
        usedFallback = lexicalOutsideCount == 0
        var values = [Float](repeating: 1, count: context.count)
        if !allOnesControl && !usedFallback {
            for index in indices { values[index] = 0 }
        }
        excludedCount = values.filter { $0 == 0 }.count
        tensor = try CTTensor(values, shape: [1, context.count, 1])
    }
}
