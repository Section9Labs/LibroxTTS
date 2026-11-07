import Foundation
@main struct QualificationCLI {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 4 else { fatalError("ASSETS GRAPHS FIXTURES OUTPUT") }
        try await ApprovedExpressionQualification.run(assets: URL(fileURLWithPath: args[0]),
            graphs: URL(fileURLWithPath: args[1]), fixtures: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
    }
}
