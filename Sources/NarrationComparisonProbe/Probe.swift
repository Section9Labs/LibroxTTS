// SPDX-License-Identifier: Apache-2.0 OR MIT
// Offline diagnostic: render each unit once, compare filters on identical PCM.
import AVFoundation
import Foundation
import LibroxTTS
import KokoroNarration
import KokoroAudio
import KokoroPronunciation

@main struct NarrationComparisonProbe {
    enum Failure: Error { case arguments, invalidAudio }
    struct RenderUnit {
        let text: String
        let phonemes: String
        let boundaryAfter: NarrationBoundary
        let expression: NarrationExpression
        let speed: Float
    }
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--filter" {
            guard args.count == 5, let preset = VoiceEnhancer.Preset(rawValue: args[2]) else { throw Failure.arguments }
            let input = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]), commonFormat: .pcmFormatFloat32, interleaved: false)
            guard input.processingFormat.sampleRate == 24_000, input.processingFormat.channelCount == 1 else { throw Failure.invalidAudio }
            let output = try AVAudioFile(forWriting: URL(fileURLWithPath: args[4]), settings: input.processingFormat.settings)
            let report = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
            let units = report["units"] as! [[String: Any]]
            var count = 0
            for unit in units {
                let record = (unit["variants"] as! [[String: Any]])[0]
                let length = record["samples"] as! Int, pause = record["addedPauseSamples"] as! Int
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(length)) else { throw Failure.invalidAudio }
                var samples: [Float] = []
                samples.reserveCapacity(length)
                while samples.count < length {
                    try input.read(into: buffer, frameCount: AVAudioFrameCount(length - samples.count))
                    guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { throw Failure.invalidAudio }
                    samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                }
                let filtered = try process(Array(samples.dropFirst(pause)), with: VoiceEnhancer(preset: preset))
                samples.replaceSubrange(pause..<length, with: filtered)
                buffer.frameLength = AVAudioFrameCount(length)
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                try output.write(from: buffer)
                count += length
            }
            guard count == input.length else { FileHandle.standardError.write(Data("Count \(count) != \(input.length)\n".utf8)); throw Failure.invalidAudio }
            print("Filtered \(count) samples using \(preset.rawValue), preserving per-unit resets and pauses")
            return
        }
        guard (6...8).contains(args.count), let voice = Voice.named(args[4]),
              args.dropFirst(6).allSatisfy({ ["--style=fixed", "--style=length", "--questions"].contains($0) }),
              !(args.contains("--style=fixed") && args.contains("--style=length")) else {
            print("Usage: narration-comparison COMPACT_DIR FRONTEND HARMONIC TEXT_FILE VOICE OUTPUT_DIR [--style=fixed|--style=length] [--questions]")
            throw Failure.arguments
        }
        // Diagnostic only: compare the established fixed reference with the
        // voice pack's length-indexed reference. No application default changes.
        let lengthIndexedStyle = args.contains("--style=length")
        let questionPhrasing = args.contains("--questions")
        let root = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: args[5])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let text = try String(contentsOfFile: args[3], encoding: .utf8)
        let cast = try BookVoiceCast(bookID: "texture-comparison", language: .init(rawValue: voice.language.rawValue)!,
            narratorVoiceID: voice.id, voicePool: [])
        let plan = try await BookNarrationPlanner().plan(text, chapterID: "1", cast: cast,
            targetPhonemes: 320, options: .init(spanishAdverbDoubleStress: true), expressiveDelivery: true)
        var renderUnits: [RenderUnit] = []
        let pronunciation = PronunciationEngine()
        let questionEnds = try NSRegularExpression(pattern: #"\?+[.!…»”\"]*"#)
        for unit in plan.units {
            guard !unit.requiresRendererSplit else { throw Failure.invalidAudio }
            let source = unit.text as NSString
            var start = 0
            if questionPhrasing {
                for match in questionEnds.matches(in: unit.text, range: NSRange(location: 0, length: source.length)) {
                    let end = NSMaxRange(match.range)
                    // Avoid creating isolated tiny questions or orphaned punctuation.
                    // This bounded diagnostic preserves every source character.
                    let fragment = source.substring(with: NSRange(location: start, length: end - start))
                    let remaining = source.substring(from: end)
                    let phones = try pronunciation.phonemize(fragment, language: cast.language.pronunciationLanguage!,
                        options: .init(spanishAdverbDoubleStress: true)).phonemes
                    guard phones.unicodeScalars.count >= 40,
                          remaining.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    renderUnits.append(.init(text: fragment, phonemes: phones, boundaryAfter: .sentence,
                        expression: .question, speed: NarrationDelivery.speed(for: unit, pacing: .audiobook)))
                    start = end
                }
            }
            let remaining = source.substring(from: start)
            let phones = start == 0 ? unit.phonemes : try pronunciation.phonemize(remaining,
                language: cast.language.pronunciationLanguage!, options: .init(spanishAdverbDoubleStress: true)).phonemes
            renderUnits.append(.init(text: remaining, phonemes: phones, boundaryAfter: unit.boundaryAfter,
                expression: unit.expression, speed: NarrationDelivery.speed(for: unit, pacing: .audiobook)))
        }
        guard renderUnits.map(\.text).joined() == plan.units.map(\.text).joined(),
              renderUnits.allSatisfy({ (1...510).contains($0.phonemes.unicodeScalars.count) }) else {
            throw Failure.invalidAudio
        }
        let audit = renderUnits.map { ["text": $0.text, "phonemes": $0.phonemes] }
        try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("plan.json"))
        let engine = KokoroEngine(modelDirectory: root, computePolicy: .cpuOnly,
            pronunciationPolicy: .independent,
            rendererPolicy: .fixedSize(directory: root.appendingPathComponent("decoder")),
            narration: .init(harmonicSource: URL(fileURLWithPath: args[2]),
                             frontend: URL(fileURLWithPath: args[1])))
        try await engine.load()
        let presets: [VoiceEnhancer.Preset] = [.bypass, .balanced, .harmonicBalanced, .speechSmooth]
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let files = try presets.map {
            try AVAudioFile(forWriting: output.appendingPathComponent($0.rawValue + "-raw.wav"), settings: format.settings)
        }
        var cadence = NarrationCadence(pacing: .audiobook)
        var records: [[String: Any]] = []
        var skippedPunctuation: [String] = []
        var offsets = presets.map { _ in 0 }
        for (index, unit) in renderUnits.enumerated() {
            // The app also skips punctuation-only source spans. Keep these in
            // plan.json/provenance; never ask the model to invent spoken audio.
            guard unit.text.contains(where: { $0.isLetter || $0.isNumber }) else {
                skippedPunctuation.append(unit.text)
                continue
            }
            let began = Date()
            let styleRow = lengthIndexedStyle ? unit.phonemes.unicodeScalars.count : 158
            let audio = try await engine.synthesizeNarration(unit.phonemes, voiceID: voice.id,
                styleRow: styleRow, speed: unit.speed)
            let renderSeconds = Date().timeIntervalSince(began)
            var timedSource = audio.samples
            let pause = cadence.apply(to: &timedSource, boundaryAfter: unit.boundaryAfter, voiceID: voice.id)
            var variants: [[String: Any]] = []
            for (i, preset) in presets.enumerated() {
                let filter = try VoiceEnhancer(preset: preset)
                let processingStart = Date()
                var samples = try process(audio.samples, with: filter)
                let processingSeconds = Date().timeIntervalSince(processingStart)
                // Freeze timing from unprocessed audio so only the filtering
                // differs between listening variants.
                if pause > 0 { samples.insert(contentsOf: repeatElement(Float.zero, count: pause), at: 0) }
                guard samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }),
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                    let channel = buffer.floatChannelData?[0] else { throw Failure.invalidAudio }
                buffer.frameLength = buffer.frameCapacity
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
                try files[i].write(from: buffer)
                variants.append(["preset": preset.rawValue, "startSeconds": Double(offsets[i]) / 24_000,
                    "samples": samples.count, "addedPauseSamples": pause,
                    "processingSeconds": processingSeconds, "workingBufferBytes": filter.workingBufferBytes,
                    "maximumReductionDB": filter.maximumReductionDB,
                    "activeFrames": filter.harmonicActiveFrames, "frames": filter.processedFrames])
                offsets[i] += samples.count
            }
            records.append(["unit": index, "text": unit.text, "phonemes": unit.phonemes,
                "styleRow": styleRow,
                "expression": unit.expression.rawValue, "renderSeconds": renderSeconds,
                "speed": unit.speed, "variants": variants])
            print("Rendered \(index + 1)/\(renderUnits.count)")
        }
        await engine.unload()
        let report: [String: Any] = ["voice": voice.id, "text": text,
            "stylePolicy": lengthIndexedStyle ? "phoneme-length" : "fixed-158",
            "questionBoundaries": questionPhrasing,
            "skippedPunctuation": skippedPunctuation,
            "delivery": NarrationDelivery.revision, "units": records,
            "scope": "Within a render, filters receive identical PCM. Separate style-policy renders regenerate audio, including excitation noise, and may differ in duration. Mac comparison, not physical iPhone validation."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("render.json"))
    }

    static func process(_ samples: [Float], with filter: VoiceEnhancer) throws -> [Float] {
        var input = [Float](repeating: 0, count: 256), output = input
        var result: [Float] = []; result.reserveCapacity(samples.count)
        for block in 0..<((samples.count + 255) / 256 + 3) {
            for i in input.indices {
                let position = block * 256 + i
                input[i] = position < samples.count ? samples[position] : 0
            }
            try filter.process(input, into: &output)
            let first = max(0, 768 - block * 256), end = min(256, 768 + samples.count - block * 256)
            if first < end { result.append(contentsOf: output[first..<end]) }
        }
        guard result.count == samples.count else { throw Failure.invalidAudio }
        return result
    }
}
