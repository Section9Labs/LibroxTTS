import Foundation
import CryptoKit
import LibroxTTS
import LibroxCTNative

/// Opt-in public-download acceptance. Uses the same SDK installer as hosts.
@main struct CTInstallProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Usage: ct-install-probe NEW_DIRECTORY"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw CocoaError(.fileWriteFileExists) }
        let start = Date()
        try await NarrationAssets.download(.plus, to: directory)
        let installSeconds = Date().timeIntervalSince(start)
        // A partial/retried download must not accept a same-size corrupt file.
        let config = directory.appendingPathComponent("config/tts.json")
        var damaged = try Data(contentsOf: config)
        damaged[0] ^= 1
        try damaged.write(to: config)
        try await NarrationAssets.download(.plus, to: directory)
        try NarrationAssets.validate(directory, manifest: NarrationAssets.manifest(.plus))
        let renderer = NarrationRenderer(compactDirectory: directory, harmonicSource: nil)
        try await renderer.load(.plus, directory: directory, executionContext: .foreground)
        var rows: [[String: Any]] = []
        for (text, voice) in [("The book was waiting where she had left it.", "plus-f1-en-v1"),
                              ("El libro estaba donde lo había dejado.", "plus-f1-es-v1")] {
            for unit in try TextNativeNarrationPlanner.plan(text, voiceID: voice) {
                let start = Date()
                let audio = try await renderer.render(unit)
                guard !audio.isEmpty && audio.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw CTError.invalidAudio }
                rows.append(["voice": voice, "samples": audio.count,
                             "synthesisSeconds": Date().timeIntervalSince(start)])
            }
        }
        await renderer.unload()
        let receipt: [String: Any] = ["release": CTAssets.releaseTag, "installSeconds": installSeconds,
            "downloadedBytes": try NarrationAssets.manifest(.plus).downloadSize,
            "sameSizeCorruptionRepaired": true, "renders": rows]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("acceptance.json"))
        print(String(decoding: data, as: UTF8.self))
    }
}
