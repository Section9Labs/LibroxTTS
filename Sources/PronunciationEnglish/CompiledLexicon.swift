import CryptoKit
import Foundation

/// Immutable, indexed dictionary bytes. Original JSON remains authoritative:
/// missing, changed or corrupt derived data uses the legacy loader. No mutable
/// lookup cache or process-lifetime ownership is introduced.
struct CompiledLexicon: Sendable {
    private let data: Data
    let count: Int
    private let payload: Int

    init?(name: String, bundle: Bundle = .module) {
        guard let expected = CompiledLexiconDigests.sha256[name],
              let url = bundle.url(forResource: name, withExtension: "lxt"),
              let original = bundle.url(forResource: name, withExtension: "json"),
              let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), bytes.count >= 40,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected,
              let json = try? Data(contentsOf: original, options: .mappedIfSafe),
              Data(SHA256.hash(data: json)) == bytes.subdata(in: 4..<36) else { return nil }
        data = bytes
        count = bytes.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 36, as: UInt32.self))) }
        payload = 40 + count * 4
    }
    private func integer(_ offset: Int) -> Int {
        data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
    }
    private func string(_ cursor: inout Int) -> String {
        let size = integer(cursor); cursor += 4
        defer { cursor += size }
        return String(decoding: data[cursor..<cursor + size], as: UTF8.self)
    }
    func key(at index: Int) -> String {
        var cursor = payload + integer(40 + index * 4)
        return string(&cursor)
    }
    func value(for key: String) -> LexiconValue? {
        // Swift Dictionary keys use canonical String equivalence (for example
        // the Kelvin sign equals K). Byte indexing must preserve that contract.
        let canonical = key.utf8.allSatisfy { $0 < 128 } ? key : key.precomposedStringWithCanonicalMapping
        let bytes = Array(canonical.utf8)
        var lower = 0, upper = count
        while lower < upper {
            let middle = (lower + upper) / 2
            var cursor = payload + integer(40 + middle * 4)
            let size = integer(cursor); cursor += 4
            let order: Int = data.withUnsafeBytes { buffer in
                let stored = buffer.bindMemory(to: UInt8.self)
                for i in 0..<min(size, bytes.count) where stored[cursor + i] != bytes[i] {
                    return stored[cursor + i] < bytes[i] ? -1 : 1
                }
                return size == bytes.count ? 0 : size < bytes.count ? -1 : 1
            }
            if order < 0 { lower = middle + 1 }
            else if order > 0 { upper = middle }
            else {
                cursor += size
                let tag = integer(cursor); cursor += 4
                if tag == 0 { return .single(string(&cursor)) }
                var variants: [String: String?] = [:]
                for _ in 0..<(tag - 1) {
                    let name = string(&cursor), value = string(&cursor)
                    variants[name] = value
                }
                return .variants(variants)
            }
        }
        return nil
    }
}

struct LexiconTable: Sendable {
    private let dictionary: [String: LexiconValue]
    private let archive: CompiledLexicon?
    init(_ dictionary: [String: LexiconValue]) { self.dictionary = dictionary; archive = nil }
    init(_ archive: CompiledLexicon) { dictionary = [:]; self.archive = archive }
    subscript(_ key: String) -> LexiconValue? { archive?.value(for: key) ?? dictionary[key] }
}

struct StringLexiconTable: Sendable {
    private var dictionary: [String: String]
    private let archive: CompiledLexicon?
    init(_ dictionary: [String: String]) { self.dictionary = dictionary; archive = nil }
    init(_ archive: CompiledLexicon) { dictionary = [:]; self.archive = archive }
    mutating func merge(_ values: [String: String]) { dictionary.merge(values, uniquingKeysWith: { _, new in new }) }
    subscript(_ key: String) -> String? {
        if let value = dictionary[key] { return value }
        if case let .single(value) = archive?.value(for: key) { return value }
        return nil
    }
}
