#if os(macOS)
import Foundation
import MLX
import CryptoKit
import Darwin

enum ReferenceEngineStudy {
    static let preregistrationSHA256 = "148b537f95864cea4b5a608571662ab368512a45eeaaaa7bd7ad9d188ddb4404"
    static let sigmoidSHA256 = "71da0d3bb8b7812e046eb6128e7538b13903c2ad0a68a6bb3c789e97aa176b7e"
    enum Failure: Error { case identity, fixture, parity, control }
    struct Files {
        let primitive: URL, scalar: URL, weights: URL, sigmoid: URL
        let preregistration: URL, script: URL, python: URL, output: URL
    }
    private final class Weights {
        let file: FileHandle, header: [String: Any], offset: Int
        let initial: stat
        init(_ path: URL, budget: CertifiedHalfProjection.Budget) throws {
            let handle = try FileHandle(forReadingFrom: path)
            do {
                var info = stat()
                guard fstat(handle.fileDescriptor, &info) == 0, info.st_size == 568662708 else { throw Failure.identity }
                var hash = SHA256()
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try budget.check(); hash.update(data: data) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() ==
                    ChatterboxMLXRenderer.DecoderProfile.q8CanonicalHalfV2.weightsSHA256 else { throw Failure.identity }
                try handle.seek(toOffset: 0)
                guard let count = try handle.read(upToCount: 8), count.count == 8 else { throw Failure.fixture }
                let rawLength = count.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
                guard (1...4_000_000).contains(rawLength) else { throw Failure.fixture }
                let length = Int(rawLength)
                guard let bytes = try handle.read(upToCount: length), bytes.count == length,
                    let header = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                    header.keys.filter({ $0 != "__metadata__" }).count == 692 else { throw Failure.fixture }
                self.file = handle; self.header = header; self.offset = length + 8; self.initial = info
                try verify()
            } catch { try? handle.close(); throw error }
        }
        deinit { try? file.close() }
        func verify() throws {
            var info = stat()
            guard fstat(file.fileDescriptor, &info) == 0, info.st_dev == initial.st_dev, info.st_ino == initial.st_ino,
                info.st_size == initial.st_size, info.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
                info.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec else { throw Failure.identity }
        }
        func values(_ name: String, shape: [Int], budget: CertifiedHalfProjection.Budget) throws -> [Float] {
            try budget.check()
            let count = shape.reduce(1, *)
            guard let entry = header[name] as? [String: Any], entry["dtype"] as? String == "F32",
                entry["shape"] as? [Int] == shape, let bounds = entry["data_offsets"] as? [Int], bounds.count == 2,
                bounds[0] >= 0, bounds[1] - bounds[0] == count * 4, bounds[1] <= Int(initial.st_size) - offset
            else { throw Failure.fixture }
            try ChatterboxMLXRenderer.healthy(minimumAvailable: count * 8 + 1_073_741_824)
            try file.seek(toOffset: UInt64(offset + bounds[0]))
            guard let data = try file.read(upToCount: count * 4), data.count == count * 4 else { throw Failure.fixture }
            var result: [Float] = []; result.reserveCapacity(count)
            try data.withUnsafeBytes { p in
                for i in 0..<count {
                    if i % 16384 == 0 { try budget.check() }
                    let value = Float(bitPattern: UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
                    guard value.isFinite else { throw Failure.fixture }; result.append(value)
                }
            }
            return result
        }
    }
    static func run(_ f: Files) throws {
        let budget = CertifiedHalfProjection.Budget()
        try budget.check()
        guard !FileManager.default.fileExists(atPath: f.output.path),
            try ChatterboxMLXRenderer.digest(f.primitive) == PrimitiveDiagnostic.fixtureSHA256,
            try ChatterboxMLXRenderer.digest(f.scalar) == ReferenceSoftmaxStudy.fixtureSHA256,
            try ChatterboxMLXRenderer.digest(f.sigmoid) == sigmoidSHA256,
            try ChatterboxMLXRenderer.digest(f.preregistration) == preregistrationSHA256 else { throw Failure.identity }
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        var report: [String: Any] = ["completed": false, "diagnostic_only": true, "production_clearance": false,
            "assembled_reference_clearance": false, "preregistration_sha256": preregistrationSHA256]
        do {
            try Device.withDefaultDevice(.cpu) {
                let source = try loadArrays(url: f.primitive), expected = try loadArrays(url: f.scalar)
                let weights = try Weights(f.weights, budget: budget)
                let resolver = try ReferenceExactResolver(script: f.script, python: f.python, directory: f.output, budget: budget)
                let statistics = CertifiedReferenceMatrix.Statistics()
                // Actual unresolved-cell and unresolved-row transport controls.
                let one = try CertifiedReferenceMatrix.prepare([1, 1, 1], rows: 1, columns: 3, budget: budget)
                let control = try CertifiedReferenceMatrix.multiply([.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .leastNonzeroMagnitude],
                    rows: 1, weight: one, output: .f32, budget: budget, statistics: statistics, resolver: resolver.dots)
                guard control.map(\.bitPattern) == [1], statistics.bigint == 1 else { throw Failure.control }
                let boundary: [Float] = [0, 0x1p-23]
                guard try CertifiedReferenceSoftmax.probabilities(boundary).values == nil else { throw Failure.control }
                let exact = try resolver.call([.softmax(boundary)])
                guard exact == [[0x3EFFFFFF, 0x3F000000]] else { throw Failure.control }
                report["actual_unresolved_dot_transport_passed"] = true
                report["actual_unresolved_softmax_transport_passed"] = true
                let data = try Data(contentsOf: f.sigmoid)
                guard data.count == 262144 else { throw Failure.fixture }
                let table = data.withUnsafeBytes { p in
                    (0..<65536).map { UInt32(littleEndian: p.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
                }
                for bits in 0..<65536 {
                    if bits & 0x7C00 == 0x7C00 {
                        guard table[bits] == 0x7FC00000 else { throw Failure.fixture }
                    } else { guard Float(bitPattern: table[bits]).isFinite else { throw Failure.fixture } }
                }
                func floats(_ name: String, shape: [Int]) throws -> [Float] {
                    guard let array = source[name], array.shape == shape,
                        [.float16, .float32].contains(array.dtype) else { throw Failure.fixture }
                    return array.dtype == .float16 ? array.asArray(Float16.self).map(Float.init) : array.asArray(Float.self)
                }
                var outputs: [String: MLXArray] = [:], rows: [[String: Any]] = [], unequal = 0, auxiliaryUnequal = 0
                func compare(_ name: String, _ values: [Float], shape: [Int], auxiliary: Bool = false) throws {
                    try budget.check()
                    guard values.count == shape.reduce(1, *), values.allSatisfy(\.isFinite),
                        let target = expected[name], target.dtype == .float32, target.shape == shape else { throw Failure.fixture }
                    let wanted = target.asArray(Float.self)
                    let count = zip(values, wanted).filter { $0.bitPattern != $1.bitPattern }.count
                    if auxiliary { auxiliaryUnequal += count }
                    else { rows.append(["name": name, "count": values.count, "unequal_bits": count]); unequal += count }
                    outputs[name] = MLXArray(values, shape)
                }
                let normNames = (0..<30).flatMap { i in
                    ["tfmr.layers.\(i).input_layernorm", "tfmr.layers.\(i).post_attention_layernorm"] } + ["tfmr.norm"]
                for name in normNames {
                    let x = try floats(name + ".input", shape: [2, 1, 1024])
                    let w = try weights.values(name + ".weight", shape: [1024], budget: budget)
                    try compare(name, CertifiedReferenceMatrix.norm(x, weights: w, budget: budget,
                        statistics: statistics, resolver: resolver.dots), shape: [2, 1, 1024])
                }
                for i in 0..<30 {
                    let stem = "tfmr.layers.\(i).mlp"
                    guard let gate = source[stem + ".gate_proj.output"], gate.dtype == .float16,
                        gate.shape == [2, 1, 4096] else { throw Failure.fixture }
                    let g = gate.asArray(Float16.self), up = try floats(stem + ".up_proj.output", shape: [2, 1, 4096])
                    var values: [Float] = []; values.reserveCapacity(g.count)
                    for j in g.indices {
                        if j % 256 == 0 { try budget.check() }
                        guard g[j].isFinite else { throw Failure.fixture }
                        let s = Float(g[j]) * Float(bitPattern: table[Int(g[j].bitPattern)])
                        values.append(s * up[j])
                    }
                    try compare(stem + ".activated", values, shape: [2, 1, 4096])
                }
                for i in 0..<30 {
                    let stem = "tfmr.layers.\(i).attention"
                    let query = try floats(stem + ".query", shape: [2, 16, 1, 64])
                    let key = try floats(stem + ".key", shape: [2, 16, 96, 64])
                    let value = try floats(stem + ".value", shape: [2, 16, 96, 64])
                    var result: [Float] = [], scoresAll: [Float] = [], probabilitiesAll: [Float] = []
                    for head in 0..<32 {
                        try budget.check()
                        let q = query[head * 64..<(head + 1) * 64].map { $0 * Float(0.125) }
                        let k = try CertifiedReferenceMatrix.prepare(Array(key[head * 6144..<(head + 1) * 6144]), rows: 96, columns: 64, budget: budget)
                        let scores = try CertifiedReferenceMatrix.multiply(q, rows: 1, weight: k, output: .f32,
                            budget: budget, statistics: statistics, resolver: resolver.dots)
                        let fast = try CertifiedReferenceSoftmax.probabilities(scores)
                        let probability: [Float]
                        if let accepted = fast.values { probability = accepted }
                        else { probability = try resolver.call([.softmax(scores)])[0].map { Float(bitPattern: $0) } }
                        var transposed: [Float] = []; transposed.reserveCapacity(6144)
                        for column in 0..<64 { for row in 0..<96 { transposed.append(value[head * 6144 + row * 64 + column]) } }
                        let v = try CertifiedReferenceMatrix.prepare(transposed, rows: 64, columns: 96, budget: budget)
                        result += try CertifiedReferenceMatrix.multiply(probability, rows: 1, weight: v, output: .f32,
                            budget: budget, statistics: statistics, resolver: resolver.dots)
                        scoresAll += scores; probabilitiesAll += probability
                    }
                    try compare(stem, result, shape: [2, 16, 1, 64])
                    try compare(stem + ".scores", scoresAll, shape: [2, 16, 1, 96], auxiliary: true)
                    try compare(stem + ".probabilities", probabilitiesAll, shape: [2, 16, 1, 96], auxiliary: true)
                }
                for i in 0..<30 {
                    let stem = "tfmr.layers.\(i)"
                    let x = try floats(stem + ".input_layernorm.input", shape: [2, 1, 1024])
                    let a = try floats(stem + ".self_attn.o_proj.output", shape: [2, 1, 1024])
                    let h = try floats(stem + ".post_attention_layernorm.input", shape: [2, 1, 1024])
                    let d = try floats(stem + ".mlp.down_proj.output", shape: [2, 1, 1024])
                    try compare(stem + ".attention_residual", zip(x, a).map(+), shape: [2, 1, 1024])
                    try compare(stem + ".mlp_residual", zip(h, d).map(+), shape: [2, 1, 1024])
                }
                let hidden = try floats("speech_head.input", shape: [2, 1024])
                let headWeights = try weights.values("speech_head.weight", shape: [8194, 1024], budget: budget)
                let prepared = try CertifiedReferenceMatrix.prepare(headWeights, rows: 8194, columns: 1024, budget: budget)
                try compare("speech_head", CertifiedReferenceMatrix.multiply(hidden, rows: 2, weight: prepared, output: .f32,
                    budget: budget, statistics: statistics, resolver: resolver.dots), shape: [2, 8194])
                try weights.verify(); try budget.check()
                report["comparisons"] = rows; report["unequal_bits"] = unequal; report["auxiliary_unequal_bits"] = auxiliaryUnequal
                report["certified_outputs"] = statistics.certified; report["exact128_outputs"] = statistics.exact128
                report["bigint_outputs"] = statistics.bigint; report["resolver_calls"] = resolver.calls
                guard rows.count == 182, outputs.count == 242 else { throw Failure.fixture }
                let raw = f.output.appendingPathComponent("engine-operator-bits.safetensors")
                try save(arrays: outputs, metadata: ["scope": "Reference engine operator qualification, not app oracle"], url: raw)
                report["raw_sha256"] = try ChatterboxMLXRenderer.digest(raw)
                guard unequal == 0, auxiliaryUnequal == 0 else { throw Failure.parity }
                try budget.check()
                report["all182_bit_identical"] = true; report["completed"] = true
                try write(report, f.output.appendingPathComponent("report.json"))
            }
        } catch {
            report["completed"] = false; report["error"] = String(describing: error)
            try? write(report, f.output.appendingPathComponent("report.json")); throw error
        }
    }
    private static func write(_ value: [String: Any], _ file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
#endif
