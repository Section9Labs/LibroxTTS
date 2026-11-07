import Darwin
import Foundation
import LibroxTTS
import PocketTTSMLX
import KokoroCatalog
import AVFoundation
@main struct Probe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Pocket TTS: \(error)\n".utf8))
            exit(1)
        }
    }
    static func run() async throws {
        let a = CommandLine.arguments
        if a.count == 4, a[1] == "--download" {
            let directory = URL(fileURLWithPath: a[2])
            try await NarrationAssets.download(.pocket, to: directory, language: a[3])
            let manifest = try NarrationAssets.manifest(.pocket, language: a[3])
            print("Installed \(a[3]): \(manifest.installedFiles.count) verified files, \(manifest.downloadSize) bytes")
            return
        }
        guard a.count == 5 || a.count == 6 else { print("pocket-tts-probe ASSET_ROOT VOICE_ID OUTPUT.wav TEXT [TEMPERATURE]"); return }
        let started = Date()
        let engine = PocketTTSEngine(directory: URL(fileURLWithPath: a[1]))
        let audio = try await engine.synthesize(a[4], voiceID: a[2], temperature: a.count == 6 ? Float(a[5]) ?? 0.3 : 0.3)
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count))!
        buffer.frameLength = buffer.frameCapacity
        audio.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: a[3]), settings: format.settings)
        try file.write(from: buffer)
        print("samples=\(audio.samples.count) rate=\(audio.sampleRate) elapsed=\(Date().timeIntervalSince(started)) peak=\(audio.samples.map { abs($0) }.max() ?? 0)")
    }
}
