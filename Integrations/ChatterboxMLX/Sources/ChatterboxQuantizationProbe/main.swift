import Foundation
import LibroxChatterboxMLX

@main struct QuantizationProbe {
    static func main() async throws {
        #if os(macOS)
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        try await ChatterboxQuantizationDiagnostic.run(configurationFile:
            URL(fileURLWithPath: CommandLine.arguments[1]))
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}
