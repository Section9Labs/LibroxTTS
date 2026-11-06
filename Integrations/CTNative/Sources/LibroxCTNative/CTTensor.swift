import Foundation

/// Diagnostic tensor transport; float32 and int64 are the frozen graph's types.
public struct CTTensor: Sendable {
    public enum Kind: String, Codable, Sendable { case float32, int64 }
    public let shape: [Int]
    public let kind: Kind
    public let data: Data
    public init(shape: [Int], kind: Kind, data: Data) throws {
        var count = 1
        for dimension in shape {
            guard dimension > 0, dimension <= 4_000_000, count <= 4_000_000 / dimension else {
                throw CTError.invalidTensor("shape")
            }
            count *= dimension
        }
        guard data.count == count * (kind == .float32 ? 4 : 8) else { throw CTError.invalidTensor("byte count") }
        self.shape = shape; self.kind = kind; self.data = data
    }
    public init(_ values: [Float], shape: [Int]) throws {
        try self.init(shape: shape, kind: .float32, data: values.withUnsafeBytes { Data($0) })
    }
    public init(_ values: [Int64], shape: [Int]) throws {
        try self.init(shape: shape, kind: .int64, data: values.withUnsafeBytes { Data($0) })
    }
    public func floats() throws -> [Float] {
        guard kind == .float32 else { throw CTError.invalidTensor("float32 required") }
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
        }
    }
}
