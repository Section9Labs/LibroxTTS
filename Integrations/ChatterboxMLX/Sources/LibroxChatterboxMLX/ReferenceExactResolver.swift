#if os(macOS)
import Foundation
import CryptoKit
import Dispatch

/// Owned, bounded public-fixture fallback transport. Never accepts model code.
final class ReferenceExactResolver {
    static let scriptSHA256 = "e9a611ef8b390e42bbb2ea0fdad623a060fbea25bc65a93bd17dc9b8ba9b41fe"
    private static let dependencies = [
        "operator_semantics.py": "242740151300cc393628a8b535ee678026b50574ebbc5f79323d597e1cdc5a4b",
        "rope_semantics.py": "b3645035eb12433256ac79dbc8fbcf3157275b02914c992e6ca2e37009fcb9b9",
        "rope_intervals.py": "ca5071be368e2c335ce872d9152c0778b5ba4827ee8ff15c1365673b0afc3a5b",
        "exact_dot.py": "2398d7584876034d36a02745e9383bb412a3fb5ea268d8b777c98e59fd8e5f4d"]
    enum Failure: Error { case identity, shape, child(Int32), response }
    struct Request: Encodable {
        let kind: String
        var left: [UInt32]? = nil
        var right: [UInt32]? = nil
        var scores: [UInt32]? = nil
        var output: String? = nil
        static func dot(_ item: CertifiedReferenceMatrix.Pending) -> Self {
            Self(kind: "dot", left: item.left.map(\.bitPattern), right: item.right.map(\.bitPattern), output: item.output.rawValue)
        }
        static func softmax(_ values: [Float]) -> Self { Self(kind: "softmax", scores: values.map(\.bitPattern)) }
    }
    private struct Envelope: Encodable {
        let schema = 1
        let id: String
        let remaining_seconds: Double
        let requests: [Request]
    }
    private struct Response: Decodable {
        struct Result: Decodable { let kind: String; let bits: [UInt32] }
        let schema: Int, id: String, request_sha256: String, results: [Result]
    }
    private let script: URL, python: URL, directory: URL
    private let budget: CertifiedHalfProjection.Budget
    private(set) var calls = 0
    init(script: URL, python: URL, directory: URL, budget: CertifiedHalfProjection.Budget) throws {
        self.script = script; self.python = python; self.directory = directory; self.budget = budget
        guard try ChatterboxMLXRenderer.digest(script) == Self.scriptSHA256,
            FileManager.default.isExecutableFile(atPath: python.path) else { throw Failure.identity }
    }
    func call(_ requests: [Request]) throws -> [[UInt32]] {
        try budget.check()
        guard try ChatterboxMLXRenderer.digest(script) == Self.scriptSHA256 else { throw Failure.identity }
        for (name, hash) in Self.dependencies {
            guard try ChatterboxMLXRenderer.digest(script.deletingLastPathComponent().appendingPathComponent(name)) == hash
            else { throw Failure.identity }
        }
        guard (1...4096).contains(requests.count) else { throw Failure.shape }
        let operands = requests.reduce(0) { $0 + ($1.left?.count ?? 0) + ($1.right?.count ?? 0) + ($1.scores?.count ?? 0) }
        guard operands <= 4_000_000 else { throw Failure.shape }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: operands * 24 + 1_073_741_824)
        let remaining = 180 - Double(DispatchTime.now().uptimeNanoseconds - budget.began) / 1e9
        guard remaining > 0 else { throw Failure.shape }
        let id = UUID().uuidString
        let requestFile = directory.appendingPathComponent("exact-\(id)-request.json")
        let responseFile = directory.appendingPathComponent("exact-\(id)-response.json")
        let logFile = directory.appendingPathComponent("exact-\(id).log")
        let data = try JSONEncoder().encode(Envelope(id: id, remaining_seconds: remaining, requests: requests))
        guard data.count <= 64 * 1024 * 1024 else { throw Failure.shape }
        try data.write(to: requestFile, options: [.atomic])
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile); defer { try? log.close() }
        let child = Process()
        child.executableURL = python
        child.arguments = [script.path, requestFile.path, responseFile.path]
        child.standardOutput = log; child.standardError = log
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"; environment["PYTHONPATH"] = ""
        child.environment = environment
        let status = try ReferenceOwnedChild().run(child, check: budget.check)
        guard status == 0 else { throw Failure.child(status) }
        try budget.check()
        let size = try responseFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...67_108_864).contains(size) else { throw Failure.response }
        try ChatterboxMLXRenderer.healthy(minimumAvailable: size * 3 + 1_073_741_824)
        let response = try JSONDecoder().decode(Response.self, from: Data(contentsOf: responseFile))
        guard response.schema == 1, response.id == id, response.results.count == requests.count,
            response.request_sha256 == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        else { throw Failure.response }
        for (request, result) in zip(requests, response.results) {
            let expectedCount = request.kind == "dot" ? 1 : (request.scores?.count ?? 0)
            guard request.kind == result.kind,
                expectedCount > 0, result.bits.count == expectedCount else { throw Failure.response }
            if request.kind == "softmax" {
                guard result.bits.allSatisfy({ Float(bitPattern: $0).isFinite && (0...1).contains(Float(bitPattern: $0)) })
                else { throw Failure.response }
            } else {
                guard let name = request.output, let output = ReferenceDyadic.Output(rawValue: name) else { throw Failure.response }
                _ = try output.value(result.bits[0])
            }
        }
        try budget.check()
        calls += 1
        return response.results.map(\.bits)
    }
    func dots(_ pending: [CertifiedReferenceMatrix.Pending]) throws -> [UInt32] {
        try call(pending.map(Request.dot)).map { $0[0] }
    }
}
#endif
