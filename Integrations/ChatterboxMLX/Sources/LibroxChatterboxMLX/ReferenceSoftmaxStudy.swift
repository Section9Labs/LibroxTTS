#if os(macOS)
import Foundation
import MLX

enum ReferenceSoftmaxStudy {
    static let fixtureSHA256 = "233c17befb0b9f82d59e151b1bb9c72cb01b13504f5708d17b89b3eb08258fe3"
    static let preregistrationSHA256 = "7dbcccd1c4ed328b548684b795b324ac0ca807bf03fdf59ed4bcd0b428b41d46"
    enum Failure: Error { case identity, fixture, mismatch }
    static func run(fixture: URL, preregistration: URL, output: URL) throws {
        let fixtureBytes = try fixture.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let preregistrationBytes = try preregistration.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard !FileManager.default.fileExists(atPath: output.path),
            (1...4_194_304).contains(fixtureBytes), (1...65_536).contains(preregistrationBytes),
            try ChatterboxMLXRenderer.digest(fixture) == fixtureSHA256,
            try ChatterboxMLXRenderer.digest(preregistration) == preregistrationSHA256 else { throw Failure.identity }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var report: [String: Any] = ["completed": false, "diagnostic_only": true,
            "production_clearance": false, "assembled_reference_clearance": false,
            "fixture_sha256": fixtureSHA256, "preregistration_sha256": preregistrationSHA256]
        do {
            try Device.withDefaultDevice(.cpu) {
                let budget = CertifiedHalfProjection.Budget()
                try budget.check()
                let arrays = try loadArrays(url: fixture)
                var rows: [[String: Any]] = [], certified = 0, unresolved = 0, mismatches = 0
                for layer in 0..<30 {
                    let stem = "tfmr.layers.\(layer).attention"
                    guard let s = arrays[stem + ".scores"], let p = arrays[stem + ".probabilities"],
                        s.dtype == .float32, p.dtype == .float32,
                        s.shape == [2, 16, 1, 96], p.shape == s.shape else { throw Failure.fixture }
                    let scores = s.asArray(Float.self), expected = p.asArray(Float.self)
                    for head in 0..<32 {
                        try budget.check()
                        let range = (head * 96)..<((head + 1) * 96)
                        let input = Array(scores[range])
                        let result = try CertifiedReferenceSoftmax.probabilities(input)
                        var record: [String: Any] = ["layer": layer, "head": head,
                            "score_bits": input.map(\.bitPattern), "unresolved_components": result.unresolvedComponents]
                        if let values = result.values {
                            let unequal = zip(values, expected[range]).filter { $0.bitPattern != $1.bitPattern }.count
                            record["bits"] = values.map(\.bitPattern)
                            record["unequal_reference_bits"] = unequal
                            certified += 1; mismatches += unequal
                        } else { unresolved += 1 }
                        rows.append(record)
                    }
                }
                guard rows.count == 960 else { throw Failure.fixture }
                report["rows"] = rows; report["certified_rows"] = certified
                report["unresolved_rows"] = unresolved; report["certified_bit_mismatches"] = mismatches
                // Unresolved rows are deliberately not filled from the fixture.
                // The separate Decimal resolver must compute them independently.
                report["all_rows_resolved"] = unresolved == 0
                report["scope"] = "Softmax component only; exact fallback and sigmoid validation still required"
                try budget.check()
                guard mismatches == 0 else { throw Failure.mismatch }
                report["completed"] = true
                try write(report, output.appendingPathComponent("fastpath-report.json"))
            }
        } catch {
            report["completed"] = false; report["error"] = String(describing: error)
            try? write(report, output.appendingPathComponent("fastpath-report.json"))
            throw error
        }
    }
    private static func write(_ value: [String: Any], _ file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
#endif
