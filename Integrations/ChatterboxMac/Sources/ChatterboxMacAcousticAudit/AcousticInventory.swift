import Foundation
import CryptoKit
#if os(macOS)
import Darwin
import MLX
import MLXNN

public enum AcousticInventoryError: Error { case input, identity, unsafeResource, cancelledOrExpired }

struct AcousticTensor: Codable, Sendable, Equatable {
    let dtype: String
    let shape: [Int]
    let data_offsets: [Int]

    func validate(payloadBytes: Int) throws {
        guard dtype == "F32", !shape.isEmpty, shape.allSatisfy({ $0 > 0 }),
              data_offsets.count == 2, data_offsets[0] >= 0,
              data_offsets[1] >= data_offsets[0], data_offsets[1] <= payloadBytes
        else { throw AcousticInventoryError.input }
        var bytes = 4
        for dimension in shape {
            let (next, overflow) = bytes.multipliedReportingOverflow(by: dimension)
            guard !overflow else { throw AcousticInventoryError.input }
            bytes = next
        }
        guard bytes == data_offsets[1] - data_offsets[0] else { throw AcousticInventoryError.input }
    }
}

struct AcousticRoute: Codable, Sendable, Equatable {
    let target: String?
    let reason: String
}

public struct AcousticInventoryReport: Codable, Sendable {
    public let state: String
    public let checkpointSHA256: String
    public let runtimeMetallibSHA256: String
    public let rawTensorCount: Int
    public let routedLearnedCount: Int
    public let constructorTensorCount: Int
    public let errors: [String]
    public let entries: [Entry]
    public let constructor: [Constructor]
    public let derivedState: [Derived]
    public let elapsedSeconds: Double
    public let modelForwards: Int
    public let constructorNoiseEvaluations: Int
    public let cpuModelConstructions: Int
    public let checkpointLoadedIntoModel: Bool
    public let renderingQualified: Bool
    public struct Entry: Codable, Sendable {
        let raw: String
        let route: AcousticRoute
        let dtype: String
        let shape: [Int]
    }
    public struct Constructor: Codable, Sendable {
        let key: String
        let shape: [Int]
        let dtype: String
        let source: String
    }
    public struct Derived: Codable, Sendable {
        let key: String
        let shape: [Int]
        let recipe: String
    }
}

/// Offline CPU constructor/header inventory. No weight payload is loaded into a
/// model and no forward, vocoder, conditioning extraction or audio export exists.
public enum AcousticInventory {
    public static let checkpointSHA256 = "e702f2c441e040bd360e59a86c85d462539759d665e41cfd1938adadd74187a3"
    public static let checkpointBytes = 2_711_113_780
    static let derived: [AcousticInventoryReport.Derived] = [
        .init(key: "decoder.randNoise", shape: [1, 80, 15000],
              recipe: "Upstream MLXRandom.seed(0); global split normal F32 on CPU; generated before estimator construction. Not a learned tensor."),
        .init(key: "encoder.embed.pos_enc.pe", shape: [1, 9999, 512],
              recipe: "Pinned Swift S3GenEspnetRelPositionalEncoding.createRelPE size5000,dModel512,F32."),
        .init(key: "encoder.up_embed.pos_enc.pe", shape: [1, 9999, 512],
              recipe: "Same independent positional-encoding constructor at upsample stage."),
        .init(key: "mel2wav.stftWindow", shape: [16],
              recipe: "Pinned Hann periodic window size16,F32."),
        .init(key: "external.trimFade", shape: [960],
              recipe: "Not constructed or applied by inventory. Before rendering: 480zeros +480 cosine ramp; no peak normalization."),
    ]

    static func route(_ raw: String) throws -> AcousticRoute {
        for prefix in ["t3.", "ve.", "s3gen.speaker_encoder.", "s3gen.tokenizer."] {
            if raw.hasPrefix(prefix) {
                let reason: String
                switch prefix {
                case "t3.": reason = "outside acoustic seam; retain qualified Standard decoder"
                case "ve.": reason = "outside acoustic seam; stock conditioning supplied as immutable input"
                case "s3gen.speaker_encoder.": reason = "outside acoustic seam; stock x-vector supplied, no recording extraction"
                default: reason = "outside acoustic seam; fixed valid speech token input, no tokenizer invocation"
                }
                return .init(target: nil, reason: reason)
            }
        }
        let key: String
        if raw.hasPrefix("s3gen.flow.") { key = String(raw.dropFirst("s3gen.flow.".count)) }
        else if raw.hasPrefix("s3gen.mel2wav.") { key = String(raw.dropFirst("s3gen.".count)) }
        else { throw AcousticInventoryError.input }
        return .init(target: AcousticKeyMapping.remapRegularS3GenKey(key),
                     reason: "pinned upstream regular S3Gen name mapping; no numeric/layout conversion")
    }

    public static func run(modelFile: URL, runtimeMetallib: URL) throws -> AcousticInventoryReport {
        let began = ContinuousClock.now
        func guardRun() throws {
            try Task.checkCancellation()
            guard began.duration(to: .now) < .seconds(180) else { throw AcousticInventoryError.cancelledOrExpired }
            let info = ProcessInfo.processInfo
            guard !info.isLowPowerModeEnabled, info.thermalState != .serious,
                  info.thermalState != .critical, try residentBytes() < 3 * 1024 * 1024 * 1024
            else { throw AcousticInventoryError.unsafeResource }
        }
        try guardRun()
        let runtimeAsset = try AcousticRuntimeAsset(url: runtimeMetallib)
        let checkpoint = try AcousticCheckpointAsset(modelFile: modelFile, check: guardRun)
        let header = checkpoint.header, digest = checkpoint.digest

        var errors: [String] = [], entries: [AcousticInventoryReport.Entry] = []
        var routed: [String: (raw: String, spec: AcousticTensor)] = [:]
        for (raw, spec) in header.sorted(by: { $0.key < $1.key }) {
            let mapping: AcousticRoute
            do { mapping = try route(raw) }
            catch { mapping = .init(target: nil, reason: "REJECTED_UNKNOWN_NAMESPACE"); errors.append("unknown raw namespace: \(raw)") }
            entries.append(.init(raw: raw, route: mapping, dtype: spec.dtype, shape: spec.shape))
            if let key = mapping.target {
                if let old = routed[key] { errors.append("route collision: \(old.raw) / \(raw) -> \(key)") }
                else { routed[key] = (raw, spec) }
            }
        }
        // The prototype's random arrays are inspected for shape/type only. They
        // cannot enter a forward or substitute for checkpoint parameters.
        // MLX bootstrap resolves its shared Metal library even for an explicit
        // CPU stream. Supply the verified runtime asset before any MLX operation.
        // This is runtime initialization, not a GPU model-forward qualification.
        try runtimeAsset.verify()
        GPU.metallib = runtimeAsset.url
        let constructor: [AcousticInventoryReport.Constructor] = try Device.withDefaultDevice(.cpu) {
            let model = CausalMaskedDiffWithXvec(meanflow: false)
            defer { Memory.clearCache() }
            try guardRun()
            let parameters = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
            let recipes = Dictionary(uniqueKeysWithValues: derived.filter { $0.key != "external.trimFade" }.map { ($0.key, $0) })
            var result: [AcousticInventoryReport.Constructor] = []
            for (key, value) in parameters.sorted(by: { $0.key < $1.key }) {
                let source: String
                if let weight = routed[key] {
                    source = weight.raw
                    if weight.spec.shape != value.shape || value.dtype != .float32 {
                        errors.append("shape/dtype mismatch: \(key) checkpoint\(weight.spec.shape) constructor\(value.shape)/\(value.dtype)")
                    }
                } else if let recipe = recipes[key] {
                    source = "derived: " + recipe.recipe
                    if recipe.shape != value.shape || value.dtype != .float32 { errors.append("derived state mismatch: \(key)") }
                } else { source = "MISSING_CHECKPOINT"; errors.append("unaccounted constructor: \(key)") }
                result.append(.init(key: key, shape: value.shape, dtype: String(describing: value.dtype), source: source))
            }
            for key in routed.keys.sorted() where parameters[key] == nil { errors.append("unexpected sanitized key: \(key)") }
            // An absent expected constructor buffer must never be waved through.
            for key in recipes.keys.sorted() where parameters[key] == nil { errors.append("missing declared derived state: \(key)") }
            return result
        }
        try guardRun()
        try runtimeAsset.verify()
        try checkpoint.verify()
        let elapsed = began.duration(to: .now).components
        return .init(state: errors.isEmpty ? "INVENTORY_MATCH_NO_FORWARD_CLEARANCE" : "INVENTORY_REJECTED",
            checkpointSHA256: digest, runtimeMetallibSHA256: AcousticRuntimeAsset.sha256, rawTensorCount: header.count, routedLearnedCount: routed.count,
            constructorTensorCount: constructor.count, errors: errors, entries: entries,
            constructor: constructor, derivedState: derived,
            elapsedSeconds: Double(elapsed.attoseconds) / 1e18 + Double(elapsed.seconds),
            modelForwards: 0, constructorNoiseEvaluations: 1, cpuModelConstructions: 1,
            checkpointLoadedIntoModel: false, renderingQualified: false)
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
    private static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw AcousticInventoryError.unsafeResource }
        return info.resident_size
    }
}
#endif
