import Foundation
import LibroxCTNative

/// Builds context from actual prepared SDK units without altering source text.
public enum NarrationTextContext {
    public typealias Binding = CTTextContext.Binding
    public typealias BindingError = CTTextContext.BindingError
    public static let revision = CTTextContext.revision

    public static func bind(contextText: String, spokenRange: NSRange, spokenText: String,
                            language: String, modelFingerprint: String, styleID: String) throws -> Binding {
        try CTTextContext.bind(contextText: contextText, spokenRange: spokenRange, spokenText: spokenText,
            language: language, modelFingerprint: modelFingerprint, styleID: styleID)
    }

    public static func validates(_ value: Binding, spokenText: String, language: String,
                                 modelFingerprint: String, styleID: String) -> Bool {
        CTTextContext.validates(value, spokenText: spokenText, language: language,
            modelFingerprint: modelFingerprint, styleID: styleID)
    }

    /// Construct a bounded window using actual prepared readings and original
    /// inter-unit separators. Prefer complete nearby units; never invent words
    /// or reuse a source offset after dictionary substitutions.
    public static func surrounding(_ units: [BookNarrationUnit], index: Int, source: String,
                                   language: String, modelFingerprint: String, styleID: String) throws -> Binding {
        guard units.indices.contains(index) else { throw BindingError.invalidRange }
        let original = source as NSString
        func assemble(_ low: Int, _ high: Int) throws -> Binding {
            var context = ""
            var selected: NSRange?
            for i in low...high {
                let unit = units[i]
                guard unit.range.location >= 0, unit.range.length >= 0,
                      unit.range.location <= original.length, unit.range.length <= original.length - unit.range.location,
                      original.substring(with: unit.range) == unit.text else { throw BindingError.invalidRange }
                if i > low {
                    let priorEnd = NSMaxRange(units[i - 1].range)
                    guard priorEnd <= unit.range.location else { throw BindingError.invalidRange }
                    let gap = original.substring(with: NSRange(location: priorEnd, length: unit.range.location - priorEnd))
                    guard !gap.contains(where: \.isNewline) else { throw BindingError.invalidRange }
                    context += gap
                }
                if i == index { selected = NSRange(location: context.utf16.count, length: unit.synthesisText.utf16.count) }
                context += unit.synthesisText
            }
            guard let selected else { throw BindingError.invalidRange }
            return try bind(contextText: context, spokenRange: selected, spokenText: units[index].synthesisText,
                            language: language, modelFingerprint: modelFingerprint, styleID: styleID)
        }
        var low = index, high = index
        var result = try assemble(low, high)
        // At most two neighbors in either direction. Stop extending a side if
        // its next whole unit cannot fit or crosses a paragraph boundary.
        var beforeOpen = true, afterOpen = true
        for _ in 0..<2 {
            if beforeOpen, low > 0 {
                if let candidate = try? assemble(low - 1, high) { low -= 1; result = candidate }
                else { beforeOpen = false }
            }
            if afterOpen, high + 1 < units.count {
                if let candidate = try? assemble(low, high + 1) { high += 1; result = candidate }
                else { afterOpen = false }
            }
        }
        return result
    }

}
