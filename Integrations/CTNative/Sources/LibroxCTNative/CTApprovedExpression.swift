import Foundation

/// Frozen cumulative Round 07 configuration for SDK/device qualification.
/// This additive asset bundle never reinterprets or replaces an installed DK model.
public enum CTApprovedExpression {
    public static let manifestSHA256 = "07166b8dbcc7de7d987e39bec031977eae8b86ca56d8c11ecb59ffe31619211e"
    public static let identity = "librox-plus-expression-round07-v1:"
        + manifestSHA256 + ":" + CTContextStyleDiagnostic.carryRevision
        + ":linear-two-step:" + CTReportingPoolEvidence.revision

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
