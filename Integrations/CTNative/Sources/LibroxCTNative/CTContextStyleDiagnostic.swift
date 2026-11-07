import CoreML
import CryptoKit
import Foundation

/// Isolated research configuration. No production caller supplies this value.
/// Its manifest identity must accompany any diagnostic audio/cache receipt.
public enum CTContextStyleDiagnostic {
    public static let carryRevision = "late-context-residual-linear2-v1"
    public enum CarryMode: String, Sendable {
        case disabled, zeroControl = "zero-control", linearTwoStep = "linear-two-step"
    }
    public struct Configuration: Sendable {
        let usesPersistentCache: Bool
        public let directory: URL
        public let manifestSHA256: String
        public let carryMode: CarryMode
        public let roleEvidence: [String: CTRolePoolEvidence]
        public let reportingEvidence: [String: CTReportingPoolEvidence]
        public var diagnosticIdentity: String {
            let base = manifestSHA256 + ":" + carryRevision + ":" + carryMode.rawValue
            guard !roleEvidence.isEmpty else { return base }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(roleEvidence) else { return base + ":invalid-role-evidence" }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let roleIdentity = base + ":" + CTRolePoolInputs.revision + ":" + digest
            guard !reportingEvidence.isEmpty else { return roleIdentity }
            guard let reportingData = try? encoder.encode(reportingEvidence) else { return roleIdentity + ":invalid-reporting-evidence" }
            return roleIdentity + ":" + CTReportingPoolEvidence.revision + ":"
                + SHA256.hash(data: reportingData).map { String(format: "%02x", $0) }.joined()
        }
        public init(directory: URL, manifestSHA256: String, carryMode: CarryMode = .disabled, roleEvidence: [String: CTRolePoolEvidence] = [:],
                    reportingEvidence: [String: CTReportingPoolEvidence] = [:]) {
            self.usesPersistentCache = false
            self.directory = directory
            self.manifestSHA256 = manifestSHA256
            self.carryMode = carryMode
            self.roleEvidence = roleEvidence
            self.reportingEvidence = reportingEvidence
        }
        init(approvedDirectory: URL) {
            directory = approvedDirectory
            manifestSHA256 = CTApprovedExpression.manifestSHA256
            carryMode = .linearTwoStep
            roleEvidence = [:]; reportingEvidence = [:]
            usesPersistentCache = true
        }

    }

    static func validateRequiredCarry(mode: String?, revision: String?, configured: CarryMode) throws {
        guard mode != nil || revision != nil else { return }
        guard mode == configured.rawValue, revision == carryRevision else {
            throw CTError.invalidAssets("required context carry mode or revision")
        }
    }

    final class Encoder {
        struct Manifest: Decodable {
            struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
            let identity: String
            let sourceModelIdentity: String
            let sourceWeightSHA256: String
            let rolePoolRevision: String?
            let rolePoolMode: String?
            let reportingPoolRevision: String?
            let reportingPoolMode: String?
            let quotePoolRevision: String?
            let quotePoolMode: String?
            let localContextQueryRevision: String?
            let terminalBoundaryRevision: String?
            let terminalBoundaryMode: String?
            let requiredCarryMode: String?
            let requiredCarryRevision: String?
            let files: [File]
        }
        struct Encoded {
            let features: MLFeatureValue
            let diagnosticFeatures: [String: MLFeatureValue]
            let seconds: [String: Double]
        }
        private let reader: MLModel
        private let spoken: MLModel
        private let rolePoolMode: String?
        private let roleEvidence: [String: CTRolePoolEvidence]
        private let reportingEvidence: [String: CTReportingPoolEvidence]
        private let reportingPoolMode: String?
        private let quotePoolMode: String?
        private let localContextQueryRevision: String?
        private let terminalBoundaryMode: String?
        private let temporaryCompiledModels: [URL]

        deinit {
            for url in temporaryCompiledModels { try? FileManager.default.removeItem(at: url) }
        }

        init(configuration: Configuration) throws {
            let data = try Data(contentsOf: configuration.directory.appendingPathComponent("manifest.json"))
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == configuration.manifestSHA256 else {
                throw CTError.invalidAssets("context style manifest")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            try CTContextStyleDiagnostic.validateRequiredCarry(mode: manifest.requiredCarryMode,
                revision: manifest.requiredCarryRevision, configured: configuration.carryMode)
            guard (manifest.quotePoolRevision == nil && manifest.quotePoolMode == nil)
                || (manifest.quotePoolRevision == CTQuotePoolInputs.revision
                    && ["exclude-spoken", "all-ones-control"].contains(manifest.quotePoolMode ?? "")) else {
                throw CTError.invalidAssets("quote pool revision or mode")
            }
            quotePoolMode = manifest.quotePoolMode
            guard (manifest.rolePoolRevision == nil && manifest.rolePoolMode == nil)
                || (manifest.rolePoolRevision == CTRolePoolInputs.revision
                    && ["narrator-owned", "all-ones-control"].contains(manifest.rolePoolMode ?? "")) else {
                throw CTError.invalidAssets("role pool revision or mode")
            }
            rolePoolMode = manifest.rolePoolMode
            roleEvidence = configuration.roleEvidence
            guard (manifest.reportingPoolRevision == nil && manifest.reportingPoolMode == nil)
                || (manifest.reportingPoolRevision == CTReportingPoolEvidence.revision
                    && ["attached-reporting", "all-keep-control"].contains(manifest.reportingPoolMode ?? "")
                    && manifest.rolePoolMode == "narrator-owned") else {
                throw CTError.invalidAssets("reporting pool revision or mode")
            }
            reportingPoolMode = manifest.reportingPoolMode
            reportingEvidence = configuration.reportingEvidence
            guard manifest.localContextQueryRevision == nil
                || manifest.localContextQueryRevision == CTContextLocalQuery.revision else {
                throw CTError.invalidAssets("unknown local context query revision")
            }
            localContextQueryRevision = manifest.localContextQueryRevision
            guard (manifest.terminalBoundaryRevision == nil && manifest.terminalBoundaryMode == nil)
                || (manifest.terminalBoundaryRevision == CTTerminalBoundary.revision
                    && ["protect-terminal", "all-ones-control"].contains(manifest.terminalBoundaryMode ?? "")) else {
                throw CTError.invalidAssets("terminal boundary revision or mode")
            }
            terminalBoundaryMode = manifest.terminalBoundaryMode
            let sourceWeight = try CTAssets.manifest().files.first {
                $0.path == "coreml/text_encoder_early.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
            }
            guard manifest.identity == "librox-dk-context-style-diagnostic-v1",
                  manifest.sourceModelIdentity == CTAssets.identity,
                  sourceWeight?.sha256 == manifest.sourceWeightSHA256 else {
                throw CTError.invalidAssets("context style source")
            }
            for file in manifest.files {
                try Task.checkCancellation()
                guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                    throw CTError.invalidAssets("context style file path")
                }
                let url = configuration.directory.appendingPathComponent(file.path)
                guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.bytes else {
                    throw CTError.invalidAssets(file.path)
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256()
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try Task.checkCancellation()
                    digest.update(data: chunk)
                }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw CTError.invalidAssets(file.path)
                }
            }
            let options = MLModelConfiguration()
            options.computeUnits = .cpuOnly // Same as the GPU-heavy SDK's text path.
            options.allowLowPrecisionAccumulationOnGPU = false
            // The shipping compiler cache deliberately accepts only its pinned
            // production manifest. Keep private diagnostic graphs outside it.
            var compiled: [URL] = []
            var retained = false
            defer {
                if !retained { for url in compiled { try? FileManager.default.removeItem(at: url) } }
            }
            func compiledURL(_ name: String) throws -> URL {
                let package = configuration.directory.appendingPathComponent(name)
                if configuration.usesPersistentCache {
                    // Only the SDK-pinned approved factory may persist these verified graphs.
                    let hashes = manifest.files.filter { $0.path.hasPrefix(name + "/") }
                        .sorted { $0.path < $1.path }.map { $0.path + ":" + $0.sha256 }
                    return try CTCompiledModelCache.modelURL(for: package,
                        verifiedIdentity: [CTApprovedExpression.identity] + hashes)
                }
                let url = try MLModel.compileModel(at: package)
                compiled.append(url)
                return url
            }
            let readerURL = try compiledURL("context_queries.mlpackage")
            reader = try MLModel(contentsOf: readerURL, configuration: options)
            try Task.checkCancellation()
            let spokenURL = try compiledURL("spoken_context.mlpackage")
            spoken = try MLModel(contentsOf: spokenURL, configuration: options)
            temporaryCompiledModels = compiled
            retained = true
        }

        func encode(context: [String: MLFeatureValue], unit: [String: MLFeatureValue], binding: CTTextContext.Binding, expression: CTExpressionInput? = nil) throws -> Encoded {
            try Task.checkCancellation()
            var started = Date()
            var contextFeed = context
            var poolFeatures: [String: MLFeatureValue] = [:]
            if let quotePoolMode {
                let input = try CTQuotePoolInputs(binding: binding, allOnesControl: quotePoolMode == "all-ones-control")
                guard context["text_ids"]?.multiArrayValue?.shape.last?.intValue == binding.normalizedContext.unicodeScalars.count else {
                    throw CTError.invalidTensor("quote pool token count")
                }
                poolFeatures["quote_pool_mask"] = try CTCoreMLGraph.feature(input.tensor)
                contextFeed.merge(poolFeatures) { _, rhs in rhs }
            }
            if let rolePoolMode {
                let tensor: CTTensor
                if let reportingPoolMode {
                    tensor = try CTReportingPoolInputs(binding: binding, roleEvidence: expression?.roles ?? roleEvidence[binding.renderCacheKey],
                        evidence: expression?.reporting ?? reportingEvidence[binding.renderCacheKey],
                        allKeepControl: reportingPoolMode == "all-keep-control").tensor
                } else {
                    tensor = try CTRolePoolInputs(binding: binding, evidence: expression?.roles ?? roleEvidence[binding.renderCacheKey],
                        allOnesControl: rolePoolMode == "all-ones-control").tensor
                }
                poolFeatures["role_pool_mask"] = try CTCoreMLGraph.feature(tensor)
                contextFeed["role_pool_mask"] = poolFeatures["role_pool_mask"]
            }
            let poolSeconds = Date().timeIntervalSince(started)
            started = Date()
            let queries = try reader.prediction(from: MLDictionaryFeatureProvider(dictionary: contextFeed))
            let querySeconds = Date().timeIntervalSince(started)
            guard let first = queries.featureValue(for: "second_97"), let second = queries.featureValue(for: "second_111"),
                  first.multiArrayValue?.shape.map(\.intValue) == [1, 1, 256],
                  second.multiArrayValue?.shape.map(\.intValue) == [1, 1, 256],
                  let contextContent = queries.featureValue(for: "first_121") else {
                throw CTError.invalidTensor("context style queries")
            }
            var feed = unit
            feed["context_query_1"] = first
            feed["context_query_2"] = second
            var localFeatures: [String: MLFeatureValue] = [:]
            var localSeconds: [String: Double] = [:]
            if let terminalBoundaryMode {
                started = Date()
                let input = try CTTerminalBoundary(normalized: binding.normalizedSpoken, language: binding.language,
                    allOnes: terminalBoundaryMode == "all-ones-control")
                guard unit["text_ids"]?.multiArrayValue?.shape.last?.intValue == binding.normalizedSpoken.unicodeScalars.count else {
                    throw CTError.invalidTensor("terminal boundary token count")
                }
                let feature = try CTCoreMLGraph.feature(input.tensor)
                feed["terminal_keep"] = feature
                localFeatures["terminal_keep"] = feature
                localSeconds["terminal_boundary_prepare"] = Date().timeIntervalSince(started)
            }
            if localContextQueryRevision != nil {
                started = Date()
                guard unit["text_ids"]?.multiArrayValue?.shape.last?.intValue == binding.gatherIndices.count else {
                    throw CTError.invalidTensor("missing local context query")
                }
                let gathered = try CTContextLocalQuery.gather(CTCoreMLGraph.tensor(contextContent), indices: binding.gatherIndices)
                let feature = try CTCoreMLGraph.feature(gathered)
                feed["context_spoken_content"] = feature
                localFeatures["context_spoken_content"] = feature
                localSeconds["context_local_query_gather"] = Date().timeIntervalSince(started)
            }
            try Task.checkCancellation()
            started = Date()
            let output = try spoken.prediction(from: MLDictionaryFeatureProvider(dictionary: feed))
            let spokenSeconds = Date().timeIntervalSince(started)
            guard let features = output.featureValue(for: "text_emb"),
                  let content = output.featureValue(for: "first_121") else {
                throw CTError.invalidTensor("context style output")
            }
            if localContextQueryRevision != nil {
                guard let residual = output.featureValue(for: "first_127") else {
                    throw CTError.invalidTensor("missing local query residual")
                }
                localFeatures["context_local_query_residual"] = residual
            }
            if terminalBoundaryMode != nil {
                for name in ["second_111", "context_style_combined_2", "terminal_selected_query"] {
                    guard let value = output.featureValue(for: name) else { throw CTError.invalidTensor("terminal query output") }
                    localFeatures[name] = value
                }
            }
            if let stage = queries.featureValue(for: "first_141") { localFeatures["reader_first_stage_content"] = stage }
            if let stage = output.featureValue(for: "first_141") { localFeatures["spoken_first_stage_content"] = stage }
            try Task.checkCancellation()
            return Encoded(features: features,
                diagnosticFeatures: ["context_style_query_1": first, "context_style_query_2": second,
                                     "isolated_pre_style_content": content,
                                     "context_pre_style_content": contextContent].merging(poolFeatures) { _, rhs in rhs }
                    .merging(localFeatures) { _, rhs in rhs },
                seconds: ["quote_pool_prepare": poolSeconds, "context_style_reader": querySeconds,
                          "context_style_spoken_encoder": spokenSeconds].merging(localSeconds) { _, rhs in rhs })
        }
    }
}
