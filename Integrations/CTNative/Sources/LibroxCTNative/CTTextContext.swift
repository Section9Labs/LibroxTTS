import CryptoKit
import Foundation

/// Binds a spoken unit to its exact normalized tokens inside surrounding prose.
/// This is input preparation, not emotion classification or a voice assignment.
public enum CTTextContext {
    public static let revision = "native-context-gather-1"
    public enum BindingError: Error {
        case invalidRange, spokenTextMismatch, reservedScalar, oversizedContext, normalizationMismatch, invalidIdentity
    }

    public struct Binding: Sendable, Codable, Equatable {
        public let revision: String
        public let contextText: String
        public let spokenText: String
        public let spokenOffsetUTF16: Int
        public let spokenLengthUTF16: Int
        public let language: String
        public let modelFingerprint: String
        public let styleID: String
        public let normalizedContext: String
        public let normalizedSpoken: String
        /// For each isolated input token, its corresponding whole-context token.
        public let gatherIndices: [Int]
        public let featureCacheKey: String
        public let renderCacheKey: String
        public var isIdentity: Bool {
            normalizedContext == normalizedSpoken && gatherIndices == Array(0..<normalizedSpoken.unicodeScalars.count)
        }
    }

    /// Call with the actual synthesisText after dictionary expansion. Temporary
    /// private-use scalars are only normalization markers; they never reach a model.
    /// Removing them must reproduce ordinary normalization exactly, or we fail.
    public static func bind(contextText: String, spokenRange: NSRange, spokenText: String,
                            language: String, modelFingerprint: String, styleID: String) throws -> Binding {
        guard !modelFingerprint.isEmpty, !styleID.isEmpty else { throw BindingError.invalidIdentity }
        let source = contextText as NSString
        guard spokenRange.location >= 0, spokenRange.length > 0,
              spokenRange.location <= source.length, spokenRange.length <= source.length - spokenRange.location,
              let selected = Range(spokenRange, in: contextText),
              Set(contextText.indices).union([contextText.endIndex]).isSuperset(of: [selected.lowerBound, selected.upperBound]) else {
            throw BindingError.invalidRange
        }
        guard String(contextText[selected]) == spokenText else { throw BindingError.spokenTextMismatch }
        let opening: Unicode.Scalar = "\u{E000}"
        let closing: Unicode.Scalar = "\u{E001}"
        guard !contextText.unicodeScalars.contains(opening), !contextText.unicodeScalars.contains(closing) else {
            throw BindingError.reservedScalar
        }
        let context = try CTTokenizer.normalize(contextText, language: language, completeSentence: false)
        let spoken = try CTTokenizer.normalize(spokenText, language: language, completeSentence: false)
        guard context.unicodeScalars.count <= 512, spoken.unicodeScalars.count <= 512 else { throw BindingError.oversizedContext }
        var markStart = selected.lowerBound, markEnd = selected.upperBound
        while markStart < markEnd, contextText[markStart].isWhitespace { markStart = contextText.index(after: markStart) }
        while markEnd > markStart, contextText[contextText.index(before: markEnd)].isWhitespace { markEnd = contextText.index(before: markEnd) }
        let marked = String(contextText[..<markStart]) + String(opening) + String(contextText[markStart..<markEnd])
            + String(closing) + String(contextText[markEnd...])
        let normalizedMarked = try CTTokenizer.normalize(marked, language: language, completeSentence: false)
        let markedScalars = Array(normalizedMarked.unicodeScalars)
        guard let start = markedScalars.firstIndex(of: opening), let end = markedScalars.firstIndex(of: closing), start < end else {
            throw BindingError.normalizationMismatch
        }
        let unmarked = String(String.UnicodeScalarView(markedScalars.filter { $0 != opening && $0 != closing }))
        guard unmarked == context else { throw BindingError.normalizationMismatch }

        // Unit normalization trims outer whitespace. The surrounding context
        // retains those separators, so exclude them from the gathered payload.
        var payloadStart = start
        var payloadEnd = end - 1
        let scalars = Array(context.unicodeScalars)
        while payloadStart < payloadEnd, CharacterSet.whitespacesAndNewlines.contains(scalars[payloadStart]) { payloadStart += 1 }
        while payloadEnd > payloadStart, CharacterSet.whitespacesAndNewlines.contains(scalars[payloadEnd - 1]) { payloadEnd -= 1 }
        let prefixCount = "<\(language)>".unicodeScalars.count
        let suffixCount = "</\(language)>".unicodeScalars.count
        guard payloadStart >= prefixCount, payloadEnd <= scalars.count - suffixCount else { throw BindingError.normalizationMismatch }
        let indices = Array(0..<prefixCount) + Array(payloadStart..<payloadEnd) + Array((scalars.count - suffixCount)..<scalars.count)
        let gathered = String(String.UnicodeScalarView(indices.map { scalars[$0] }))
        guard gathered == spoken else { throw BindingError.normalizationMismatch }
        let keyFields = [revision, modelFingerprint, styleID, language, context]
        let keyData = try JSONEncoder().encode(keyFields)
        let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
        let renderKeyData = try JSONEncoder().encode([key, spoken, indices.map(String.init).joined(separator: ",")])
        let renderKey = SHA256.hash(data: renderKeyData).map { String(format: "%02x", $0) }.joined()
        return Binding(revision: revision, contextText: contextText, spokenText: spokenText,
                       spokenOffsetUTF16: spokenRange.location, spokenLengthUTF16: spokenRange.length,
                       language: language, modelFingerprint: modelFingerprint, styleID: styleID,
                       normalizedContext: context, normalizedSpoken: spoken, gatherIndices: indices,
                       featureCacheKey: key, renderCacheKey: renderKey)
    }

    public static func modelFingerprint() throws -> String {
        let manifest = try CTAssets.manifest()
        let fields = [manifest.identity, manifest.referenceManifestSHA256]
            + manifest.files.sorted { $0.path < $1.path }.flatMap { [$0.path, $0.sha256] }
        return SHA256.hash(data: try JSONEncoder().encode(fields)).map { String(format: "%02x", $0) }.joined()
    }

    /// Decoded metadata is untrusted. Rebuild the binding for the current model,
    /// style and spoken text; a stale binding must not change speech generation.
    public static func validates(_ value: Binding, spokenText: String, language: String,
                                 modelFingerprint: String, styleID: String) -> Bool {
        guard value.revision == revision, value.spokenText == spokenText,
              value.language == language, value.modelFingerprint == modelFingerprint, value.styleID == styleID,
              let rebuilt = try? bind(contextText: value.contextText,
                spokenRange: NSRange(location: value.spokenOffsetUTF16, length: value.spokenLengthUTF16),
                spokenText: spokenText, language: language, modelFingerprint: modelFingerprint, styleID: styleID) else { return false }
        return rebuilt == value
    }
}
