import Foundation
import LibroxCTNative
@main struct QualificationCLI {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard (4...5).contains(args.count) else { fatalError("ASSETS GRAPHS FIXTURES OUTPUT [installed]") }
        try await ApprovedExpressionQualification.run(assets: URL(fileURLWithPath: args[0]),
            graphs: URL(fileURLWithPath: args[1]), fixtures: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
            repositoryID: args.count == 5 ? CTApprovedExpression.installationIdentity : CTAssets.identity)
    }
}
