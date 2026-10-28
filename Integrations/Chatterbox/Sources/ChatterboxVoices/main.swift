import Foundation
import LibroxChatterbox

@main struct VoicesCLI {
    struct Import: Decodable {
        let name: String
        let language: String
        let origin: ChatterboxVoiceOrigin
        let referenceSHA256: String
        let referenceSeconds: Double
        let listeningAccepted: Bool
    }
    enum Failure: Error { case arguments }
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { throw Failure.arguments }
        let store = try ChatterboxVoiceStore(directory: URL(fileURLWithPath: args[1]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch args[0] {
        case "list" where args.count == 2:
            FileHandle.standardOutput.write(try encoder.encode(await store.voices()))
        case "import" where args.count == 4:
            let spec = try JSONDecoder().decode(Import.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let voice = try await store.save(name: spec.name, language: spec.language,
                conditioningFile: URL(fileURLWithPath: args[2]), origin: spec.origin,
                referenceSHA256: spec.referenceSHA256, referenceSeconds: spec.referenceSeconds,
                listeningAccepted: spec.listeningAccepted)
            FileHandle.standardOutput.write(try encoder.encode(voice))
        default: throw Failure.arguments
        }
    }
}
