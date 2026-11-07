import Foundation
import CryptoKit

/// Frozen cumulative Round 07 configuration for SDK/device qualification.
/// This additive asset bundle never reinterprets or replaces an installed DK model.
public enum CTApprovedExpression {
    public static let installationIdentity = "librox-plus-dk-expression-round07-v1"
    public static let releaseTag = "plus-dk-expression-round07-v1"
    /// The public selection stays on DK v2 until the expression release is published.
    public static let isDownloadPublished = false
    public static let manifestSHA256 = "07166b8dbcc7de7d987e39bec031977eae8b86ca56d8c11ecb59ffe31619211e"
    public static let identity = "librox-plus-expression-round07-v1:"
        + manifestSHA256 + ":" + CTContextStyleDiagnostic.carryRevision
        + ":linear-two-step:" + CTReportingPoolEvidence.revision

    /// SDK-pinned additive files. The original DK weights and graph bytes remain
    /// unchanged, with expression graphs in a distinct installation namespace.
    static func files() throws -> [CTAssets.Manifest.File] {
        guard let url = Bundle.module.url(forResource: "CTExpressionManifest", withExtension: "json") else {
            throw CTError.invalidAssets("expression SDK manifest")
        }
        let data = try Data(contentsOf: url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifestSHA256 else {
            throw CTError.invalidAssets("expression SDK manifest digest")
        }
        struct Files: Decodable { let files: [CTAssets.Manifest.File] }
        let files = try JSONDecoder().decode(Files.self, from: data).files
        guard let noticeURL = Bundle.module.url(forResource: "CTExpressionModifications", withExtension: "md") else {
            throw CTError.invalidAssets("expression modifications notice")
        }
        let notice = try Data(contentsOf: noticeURL)
        let noticeSHA = SHA256.hash(data: notice).map { String(format: "%02x", $0) }.joined()
        return files.map { .init(path: "expression/" + $0.path, bytes: $0.bytes, sha256: $0.sha256) }
            + [.init(path: "expression/manifest.json", bytes: data.count, sha256: manifestSHA256),
               .init(path: "expression/MODIFICATIONS.md", bytes: notice.count, sha256: noticeSHA)]
    }

    static func prepare(installation: URL) throws {
        // Load/release the two text encoders once to prepare their verified
        // persistent compiler output. This never starts an audio session.
        _ = try CTContextStyleDiagnostic.Encoder(configuration:
            configuration(directory: installation.appendingPathComponent("expression")))
    }

    public static func configuration(directory: URL) -> CTContextStyleDiagnostic.Configuration {
        .init(approvedDirectory: directory)
    }
}

/// Per-unit evidence; never retained by the engine across voices or chapters.
public struct CTExpressionInput: Sendable, Equatable {
    public let roles: CTRolePoolEvidence
    public let reporting: CTReportingPoolEvidence
    public var binding: CTTextContext.Binding { roles.binding }
    public var cacheIdentity: String {
        CTApprovedExpression.identity + ":" + binding.renderCacheKey
            + ":roles=" + roles.identity + ":reporting=" + reporting.identity
    }
    public init(roles: CTRolePoolEvidence, reporting: CTReportingPoolEvidence) throws {
        guard roles.binding == reporting.binding else { throw CTError.invalidTensor("expression evidence binding") }
        self.roles = roles; self.reporting = reporting
    }
}
