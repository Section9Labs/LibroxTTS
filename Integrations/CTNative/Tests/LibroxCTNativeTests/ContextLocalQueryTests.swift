import Testing
@testable import LibroxCTNative

@Test func contextLocalQueryGathersTokenRowsExactly() throws {
    let values = (0..<(12 * 256)).map(Float.init)
    let source = try CTTensor(values, shape: [1, 12, 256])
    let indices = [0, 1, 2, 6, 7, 8, 10, 11]
    let gathered = try CTContextLocalQuery.gather(source, indices: indices)
    #expect(gathered.shape == [1, 8, 256])
    #expect(try gathered.floats() == indices.flatMap { Array(values[($0 * 256)..<(($0 + 1) * 256)]) })
    #expect(try CTContextLocalQuery.gather(source, indices: Array(0..<12)).data == source.data)
}

@Test func contextLocalQueryRejectsMalformedTensors() throws {
    let source = try CTTensor([Float](repeating: 1, count: 8 * 256), shape: [1, 8, 256])
    #expect(throws: CTError.self) { try CTContextLocalQuery.gather(source, indices: [0, 1, 2, 3, 4, 5, 6, 8]) }
    #expect(throws: CTError.self) { try CTContextLocalQuery.gather(source, indices: [0, 1]) }
    let nonfinite = try CTTensor([Float](repeating: .nan, count: 8 * 256), shape: [1, 8, 256])
    #expect(throws: CTError.self) { try CTContextLocalQuery.gather(nonfinite, indices: Array(0..<8)) }
}
