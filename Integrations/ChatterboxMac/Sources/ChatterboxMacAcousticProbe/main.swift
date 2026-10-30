import Foundation
import ChatterboxMacAcousticAudit
#if os(macOS)
import Darwin
@main struct InventoryProbe {
    static func main() {
        do { try inspect() }
        catch {
            let message = "inventory_failed: " + String(describing: error).prefix(512) + "\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
    private static func inspect() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == "0"
        else { throw AcousticInventoryError.input }
        let output = URL(fileURLWithPath: args[1])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw AcousticInventoryError.input }
        let report = try AcousticInventory.run(modelFile: URL(fileURLWithPath: args[0]), runtimeMetallib: URL(fileURLWithPath: args[2]))
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
        print("\(report.state): raw=\(report.rawTensorCount) routed=\(report.routedLearnedCount) constructor=\(report.constructorTensorCount) errors=\(report.errors.count), zero forwards")
        guard report.errors.isEmpty else { throw AcousticInventoryError.input }
    }
}
#else
@main struct InventoryProbe { static func main() { fatalError("Mac offline inventory only") } }
#endif
