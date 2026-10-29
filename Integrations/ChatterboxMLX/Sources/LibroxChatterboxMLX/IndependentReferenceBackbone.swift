#if os(macOS)
import Foundation
import CryptoKit
import Darwin

/// Offline assembled reference, with its own cache trajectory. No MLX model,
/// sampler, renderer, app oracle, or production profile uses this implementation.
final class IndependentReferenceBackbone {
    enum Failure: Error { case identity, shape, nonfinite, cache }
    struct Layer {
        let inputNorm: [Float], postNorm: [Float]
        let q: CertifiedReferenceMatrix.Prepared, k: CertifiedReferenceMatrix.Prepared
        let v: CertifiedReferenceMatrix.Prepared, o: CertifiedReferenceMatrix.Prepared
        let gate: CertifiedReferenceMatrix.Prepared, up: CertifiedReferenceMatrix.Prepared
        let down: CertifiedReferenceMatrix.Prepared
    }
    /// Storage is independent from the native cache, but snapshots have the
    /// identical logical [lane,head,activePosition,dimension] order and F16 bits.
    final class Cache {
        static let capacity = 1536
        private(set) var length = 0
        private var keys: [Float16] = []
        private var values: [Float16] = []
        func append(keys incomingK: [Float], values incomingV: [Float], rows: Int,
                    offset: Int, budget: CertifiedHalfProjection.Budget) throws {
            try budget.check()
            guard (1...512).contains(rows), offset == length, offset + rows <= Self.capacity,
                incomingK.count == 32 * rows * 64, incomingV.count == incomingK.count,
                incomingK.allSatisfy(\.isFinite), incomingV.allSatisfy(\.isFinite)
            else { throw Failure.cache }
            if keys.isEmpty {
                try ChatterboxMLXRenderer.healthy(minimumAvailable: 32 * Self.capacity * 64 * 4 + 1_073_741_824)
                keys = Array(repeating: 0, count: 32 * Self.capacity * 64)
                values = Array(repeating: 0, count: keys.count)
            }
            for head in 0..<32 {
                try budget.check()
                for row in 0..<rows { for d in 0..<64 {
                    let source = (head * rows + row) * 64 + d
                    let target = (head * Self.capacity + offset + row) * 64 + d
                    let k = Float16(incomingK[source]), v = Float16(incomingV[source])
                    guard k.isFinite, v.isFinite,
                        Float(k).bitPattern == incomingK[source].bitPattern,
                        Float(v).bitPattern == incomingV[source].bitPattern else { throw Failure.cache }
                    keys[target] = k; values[target] = v
                } }
            }
            length += rows
        }
        func head(_ head: Int, values selectValues: Bool = false) throws -> [Float] {
            guard (0..<32).contains(head), length > 0 else { throw Failure.cache }
            let source = selectValues ? values : keys
            return source[(head * Self.capacity * 64)..<(head * Self.capacity * 64 + length * 64)].map(Float.init)
        }
        func snapshot() throws -> (keys: [Float16], values: [Float16]) {
            guard length > 0 else { throw Failure.cache }
            var k: [Float16] = [], v: [Float16] = []
            k.reserveCapacity(32 * length * 64); v.reserveCapacity(k.capacity)
            for head in 0..<32 {
                let range = head * Self.capacity * 64..<(head * Self.capacity * 64 + length * 64)
                k.append(contentsOf: keys[range]); v.append(contentsOf: values[range])
            }
            return (k, v)
        }
    }
    private let layers: [Layer], normWeights: [Float], head: CertifiedReferenceMatrix.Prepared
    private let cosines: [Float16], sines: [Float16], sigmoid: [UInt32]
    private let budget: CertifiedHalfProjection.Budget, resolver: ReferenceExactResolver
    let statistics = CertifiedReferenceMatrix.Statistics()
    private let caches = (0..<30).map { _ in Cache() }
    private let lifetime = ReferenceForwardLifetime()
    private(set) var forwards = 0
    var offset: Int { caches[0].length }

    init(weights: URL, rope: URL, sigmoid: URL, budget: CertifiedHalfProjection.Budget,
         resolver: ReferenceExactResolver) throws {
        self.budget = budget; self.resolver = resolver
        try budget.check()
        let r = try ReferencePinnedBytes.load(rope, count: 196736,
            sha256: "1d58a8abbe8e7f9c668cbc3d3b53bee8563e43f7cdb4cb8b758100f7ec664ca9", budget: budget)
        let s = try ReferencePinnedBytes.load(sigmoid, count: 262144,
            sha256: ReferenceEngineStudy.sigmoidSHA256, budget: budget)
        func halfTable(_ offset: Int) -> [Float16] {
            r.withUnsafeBytes { raw in (0..<49152).map {
                Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + $0 * 2, as: UInt16.self)))
            } }
        }
        cosines = halfTable(128); sines = halfTable(128 + 49152 * 2)
        self.sigmoid = s.withUnsafeBytes { raw in (0..<65536).map {
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))
        } }
        guard cosines.allSatisfy(\.isFinite), sines.allSatisfy(\.isFinite) else { throw Failure.nonfinite }
        let source = try ReferenceBackboneWeights(weights, budget: budget)
        var blocks: [Layer] = []
        for index in 0..<30 {
            try budget.check()
            let p = "tfmr.layers.\(index)."
            blocks.append(try Layer(
                inputNorm: source.f32(p + "input_layernorm.weight", shape: [1024]),
                postNorm: source.f32(p + "post_attention_layernorm.weight", shape: [1024]),
                q: source.projection(p + "self_attn.q_proj", rows: 1024, columns: 1024),
                k: source.projection(p + "self_attn.k_proj", rows: 1024, columns: 1024),
                v: source.projection(p + "self_attn.v_proj", rows: 1024, columns: 1024),
                o: source.projection(p + "self_attn.o_proj", rows: 1024, columns: 1024),
                gate: source.projection(p + "mlp.gate_proj", rows: 4096, columns: 1024),
                up: source.projection(p + "mlp.up_proj", rows: 4096, columns: 1024),
                down: source.projection(p + "mlp.down_proj", rows: 1024, columns: 4096)))
        }
        layers = blocks
        normWeights = try source.f32("tfmr.norm.weight", shape: [1024])
        head = try CertifiedReferenceMatrix.prepare(source.f32("speech_head.weight", shape: [8194, 1024]),
            rows: 8194, columns: 1024, budget: budget)
        try source.verify(); try budget.check()
    }

    /// Separate half product and half sum/difference boundaries, not an FMA.
    static func rotate(_ a: Float, _ b: Float, cosine c: Float16, sine s: Float16) throws -> (Float, Float) {
        guard a.isFinite, b.isFinite, c.isFinite, s.isFinite else { throw Failure.nonfinite }
        let ac = Float16(a * Float(c)), bs = Float16(b * Float(s))
        let `as` = Float16(a * Float(s)), bc = Float16(b * Float(c))
        let first = Float16(Float(ac) - Float(bs)), second = Float16(Float(`as`) + Float(bc))
        guard first.isFinite, second.isFinite else { throw Failure.nonfinite }
        return (Float(first), Float(second))
    }
    private func rotary(_ input: [Float], rows: Int, offset: Int) throws -> [Float] {
        guard input.count == 2 * rows * 1024, offset >= 0, offset + rows <= 1536 else { throw Failure.shape }
        var output = [Float](repeating: 0, count: input.count)
        for lane in 0..<2 { for head in 0..<16 {
            try budget.check()
            for row in 0..<rows { for d in 0..<32 {
                let start = (lane * rows + row) * 1024 + head * 64
                let index = (offset + row) * 32 + d
                let pair = try Self.rotate(input[start + d], input[start + d + 32], cosine: cosines[index], sine: sines[index])
                let target = ((lane * 16 + head) * rows + row) * 64
                output[target + d] = pair.0; output[target + d + 32] = pair.1
            } }
        } }
        return output
    }
    private func projection(_ x: [Float], rows: Int, weight: CertifiedReferenceMatrix.Prepared) throws -> [Float] {
        try budget.check()
        let half = x.map { Float(Float16($0)) }
        guard half.allSatisfy(\.isFinite) else { throw Failure.nonfinite }
        return try CertifiedReferenceMatrix.multiply(half, rows: rows, weight: weight, output: .f16,
            budget: budget, statistics: statistics, resolver: resolver.dots)
    }
    private func norm(_ x: [Float], weights: [Float]) throws -> [Float] {
        try CertifiedReferenceMatrix.norm(x, weights: weights, budget: budget, statistics: statistics, resolver: resolver.dots)
    }
    private func attention(_ x: [Float], rows: Int, layer: Layer, cache: Cache) throws -> [Float] {
        let incomingOffset = cache.length
        let q = try rotary(projection(x, rows: 2 * rows, weight: layer.q), rows: rows, offset: incomingOffset)
        let k = try rotary(projection(x, rows: 2 * rows, weight: layer.k), rows: rows, offset: incomingOffset)
        let v = try projection(x, rows: 2 * rows, weight: layer.v)
        var transposedV = [Float](repeating: 0, count: v.count)
        for lane in 0..<2 { for head in 0..<16 { for row in 0..<rows { for d in 0..<64 {
            transposedV[((lane * 16 + head) * rows + row) * 64 + d] = v[(lane * rows + row) * 1024 + head * 64 + d]
        } } } }
        try cache.append(keys: k, values: transposedV, rows: rows, offset: incomingOffset, budget: budget)
        let total = cache.length
        var result = [Float](repeating: 0, count: x.count)
        for headIndex in 0..<32 {
            try budget.check()
            let query = q[(headIndex * rows * 64)..<((headIndex + 1) * rows * 64)].map { $0 * Float(0.125) }
            let key = try CertifiedReferenceMatrix.prepare(cache.head(headIndex), rows: total, columns: 64, budget: budget)
            let scores = try CertifiedReferenceMatrix.multiply(query, rows: rows, weight: key, output: .f32,
                budget: budget, statistics: statistics, resolver: resolver.dots)
            // Only the visible prefix participates in normalization. Future and
            // padding entries stay exactly0, including during a partial chunk.
            let probabilities = try ReferenceCausalProbabilities.make(scores, rows: rows, total: total,
                incomingOffset: incomingOffset, budget: budget, resolve: resolver.call)
            let values = try cache.head(headIndex, values: true)
            var transposed: [Float] = []; transposed.reserveCapacity(total * 64)
            for d in 0..<64 { for row in 0..<total { transposed.append(values[row * 64 + d]) } }
            let prepared = try CertifiedReferenceMatrix.prepare(transposed, rows: 64, columns: total, budget: budget)
            let attended = try CertifiedReferenceMatrix.multiply(probabilities, rows: rows, weight: prepared, output: .f32,
                budget: budget, statistics: statistics, resolver: resolver.dots)
            for row in 0..<rows { for d in 0..<64 {
                result[((headIndex / 16) * rows + row) * 1024 + (headIndex % 16) * 64 + d] = attended[row * 64 + d]
            } }
        }
        return try projection(result, rows: 2 * rows, weight: layer.o)
    }
    func logits(_ embeddings: [Float], rows: Int) throws -> [Float] {
        try lifetime.run { try forward(embeddings, rows: rows) }
    }
    func snapshot() throws -> [(keys: [Float16], values: [Float16])] {
        try lifetime.requireValid(); try budget.check()
        return try caches.map { try $0.snapshot() }
    }
    private func forward(_ embeddings: [Float], rows: Int) throws -> [Float] {
        try budget.check()
        guard (1...512).contains(rows), embeddings.count == 2 * rows * 1024,
            embeddings.allSatisfy(\.isFinite), offset + rows <= 1536,
            caches.allSatisfy({ $0.length == offset }) else { throw Failure.shape }
        var h = embeddings
        for (index, layer) in layers.enumerated() {
            try budget.check()
            let a = try attention(norm(h, weights: layer.inputNorm), rows: rows, layer: layer, cache: caches[index])
            h = zip(h, a).map(+)
            let n = try norm(h, weights: layer.postNorm)
            let g = try projection(n, rows: 2 * rows, weight: layer.gate)
            let u = try projection(n, rows: 2 * rows, weight: layer.up)
            var activated = [Float](repeating: 0, count: g.count)
            for i in g.indices {
                if i % 4096 == 0 { try budget.check() }
                let gate = Float16(g[i]), sig = Float(bitPattern: sigmoid[Int(gate.bitPattern)])
                guard gate.isFinite, sig.isFinite else { throw Failure.nonfinite }
                let scaled: Float = g[i] * sig
                activated[i] = scaled * u[i]
            }
            let d = try projection(activated, rows: 2 * rows, weight: layer.down)
            h = zip(h, d).map(+)
            guard h.allSatisfy(\.isFinite) else { throw Failure.nonfinite }
        }
        let normalized = try norm(h, weights: normWeights)
        let last = Array(normalized[((rows - 1) * 1024)..<(rows * 1024)]) +
            Array(normalized[((2 * rows - 1) * 1024)..<(2 * rows * 1024)])
        let logits = try CertifiedReferenceMatrix.multiply(last, rows: 2, weight: head, output: .f32,
            budget: budget, statistics: statistics, resolver: resolver.dots)
        try budget.check(); forwards += 1
        return logits
    }
}

/// A failed incremental forward permanently invalidates its trajectory, including
/// errors after the last cache append but before the logits commit boundary.
final class ReferenceForwardLifetime {
    private var valid = true
    func requireValid() throws {
        guard valid else { throw IndependentReferenceBackbone.Failure.cache }
    }
    func run<T>(_ body: () throws -> T) throws -> T {
        try requireValid()
        do { return try body() }
        catch { valid = false; throw error }
    }
}

enum ReferencePinnedBytes {
    static func load(_ url: URL, count: Int, sha256: String,
                     budget: CertifiedHalfProjection.Budget) throws -> Data {
        try budget.check()
        guard (1...1_048_576).contains(count) else { throw IndependentReferenceBackbone.Failure.shape }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var before = stat(), after = stat()
        guard fstat(file.fileDescriptor, &before) == 0, before.st_size == count,
            let data = try file.read(upToCount: count + 1), data.count == count,
            try file.read(upToCount: 1)?.isEmpty != false,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256,
            fstat(file.fileDescriptor, &after) == 0, after.st_size == before.st_size,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
        else { throw IndependentReferenceBackbone.Failure.identity }
        try budget.check(); return data
    }
}

enum ReferenceCausalProbabilities {
    static func make(_ scores: [Float], rows: Int, total: Int, incomingOffset: Int,
                     budget: CertifiedHalfProjection.Budget,
                     resolve: ([ReferenceExactResolver.Request]) throws -> [[UInt32]]) throws -> [Float] {
        guard (1...512).contains(rows), incomingOffset >= 0, total == incomingOffset + rows,
            total <= 1536, scores.count == rows * total, scores.allSatisfy(\.isFinite)
        else { throw IndependentReferenceBackbone.Failure.shape }
        var probabilities = [Float](repeating: 0, count: scores.count)
        var pending: [ReferenceExactResolver.Request] = [], pendingRows: [Int] = []
        for row in 0..<rows {
            try budget.check()
            let visible = incomingOffset + row + 1
            let active = Array(scores[(row * total)..<(row * total + visible)])
            let fast = try CertifiedReferenceSoftmax.probabilities(active)
            if let values = fast.values {
                probabilities.replaceSubrange((row * total)..<(row * total + visible), with: values)
            } else { pending.append(.softmax(active)); pendingRows.append(row) }
        }
        if !pending.isEmpty {
            let resolved = try resolve(pending)
            guard resolved.count == pending.count else { throw IndependentReferenceBackbone.Failure.shape }
            for (row, bits) in zip(pendingRows, resolved) {
                let visible = incomingOffset + row + 1
                guard bits.count == visible,
                    bits.allSatisfy({ Float(bitPattern: $0).isFinite && (0...1).contains(Float(bitPattern: $0)) })
                else { throw IndependentReferenceBackbone.Failure.shape }
                probabilities.replaceSubrange((row * total)..<(row * total + visible), with: bits.map { Float(bitPattern: $0) })
            }
        }
        try budget.check(); return probabilities
    }
}

enum ReferenceQ8Reconstruction {
    static func decode(packed: Data, scales: Data, biases: Data, rows: Int, columns: Int,
                       budget: CertifiedHalfProjection.Budget) throws -> [Float] {
        guard (1...4096).contains(rows), (64...4096).contains(columns), columns % 64 == 0,
            packed.count == rows * columns, scales.count == rows * columns / 32,
            biases.count == scales.count else { throw IndependentReferenceBackbone.Failure.shape }
        try budget.check()
        try ChatterboxMLXRenderer.healthy(minimumAvailable: rows * columns * 12 + 1_073_741_824)
        var values: [Float] = []; values.reserveCapacity(rows * columns)
        try packed.withUnsafeBytes { wp in try scales.withUnsafeBytes { sp in try biases.withUnsafeBytes { bp in
            for row in 0..<rows {
                if row % 16 == 0 { try budget.check() }
                for group in 0..<(columns / 64) {
                    let index = row * (columns / 64) + group
                    let scale = Float(Float16(bitPattern: UInt16(littleEndian: sp.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))))
                    let bias = Float(Float16(bitPattern: UInt16(littleEndian: bp.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))))
                    guard scale.isFinite, bias.isFinite else { throw IndependentReferenceBackbone.Failure.nonfinite }
                    for j in 0..<16 {
                        let offset = row * columns + group * 64 + j * 4
                        let word = UInt32(littleEndian: wp.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                        for byte in 0..<4 {
                            let product: Float = Float((word >> (8 * byte)) & 255) * scale
                            let reconstructed: Float = product + bias
                            let half = Float16(reconstructed)
                            guard half.isFinite else { throw IndependentReferenceBackbone.Failure.nonfinite }
                            values.append(Float(half))
                        }
                    }
                }
            }
        } } }
        try budget.check(); return values
    }
}

/// Exact pinned file reader and canonical Q8 reconstruction. It never calls a
/// native projection kernel and retains no original packed-weight dictionary.
private final class ReferenceBackboneWeights {
    private let file: FileHandle, header: [String: Any], base: Int, initial: stat
    private let budget: CertifiedHalfProjection.Budget
    init(_ url: URL, budget: CertifiedHalfProjection.Budget) throws {
        self.budget = budget
        let file = try FileHandle(forReadingFrom: url)
        do {
            var state = stat()
            guard fstat(file.fileDescriptor, &state) == 0, state.st_size == 568662708 else { throw IndependentReferenceBackbone.Failure.identity }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { try budget.check(); hash.update(data: bytes) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() ==
                ChatterboxMLXRenderer.DecoderProfile.q8CanonicalHalfV2.weightsSHA256 else { throw IndependentReferenceBackbone.Failure.identity }
            try file.seek(toOffset: 0)
            guard let lengthBytes = try file.read(upToCount: 8), lengthBytes.count == 8 else { throw IndependentReferenceBackbone.Failure.shape }
            let length = lengthBytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
            guard (1...4_000_000).contains(length), let data = try file.read(upToCount: Int(length)), data.count == Int(length),
                let header = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                header.keys.filter({ $0 != "__metadata__" }).count == 692 else { throw IndependentReferenceBackbone.Failure.shape }
            self.file = file; self.header = header; base = Int(length) + 8; initial = state
            try verify()
        } catch { try? file.close(); throw error }
    }
    deinit { try? file.close() }
    func verify() throws {
        var current = stat()
        guard fstat(file.fileDescriptor, &current) == 0, current.st_dev == initial.st_dev,
            current.st_ino == initial.st_ino, current.st_size == initial.st_size,
            current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
            current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec else { throw IndependentReferenceBackbone.Failure.identity }
    }
    private func bytes(_ key: String, type: String, shape: [Int], width: Int) throws -> Data {
        try budget.check()
        let count = shape.reduce(1, *) * width
        guard let item = header[key] as? [String: Any], item["dtype"] as? String == type,
            item["shape"] as? [Int] == shape, let range = item["data_offsets"] as? [Int], range.count == 2,
            range[0] >= 0, range[1] - range[0] == count, range[1] <= Int(initial.st_size) - base
        else { throw IndependentReferenceBackbone.Failure.shape }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: count * 3 + 1_073_741_824)
        try file.seek(toOffset: UInt64(base + range[0]))
        guard let data = try file.read(upToCount: count), data.count == count else { throw IndependentReferenceBackbone.Failure.shape }
        return data
    }
    func f32(_ key: String, shape: [Int]) throws -> [Float] {
        let data = try bytes(key, type: "F32", shape: shape, width: 4)
        let result = data.withUnsafeBytes { raw in (0..<(data.count / 4)).map {
            Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)))
        } }
        guard result.allSatisfy(\.isFinite) else { throw IndependentReferenceBackbone.Failure.nonfinite }
        return result
    }
    func projection(_ key: String, rows: Int, columns: Int) throws -> CertifiedReferenceMatrix.Prepared {
        let packed = try bytes(key + ".weight", type: "U32", shape: [rows, columns / 4], width: 4)
        let scales = try bytes(key + ".scales", type: "F16", shape: [rows, columns / 64], width: 2)
        let biases = try bytes(key + ".biases", type: "F16", shape: [rows, columns / 64], width: 2)
        let values = try ReferenceQ8Reconstruction.decode(packed: packed, scales: scales, biases: biases,
            rows: rows, columns: columns, budget: budget)
        return try CertifiedReferenceMatrix.prepare(values, rows: rows, columns: columns, budget: budget)
    }
}
#endif
