import Foundation
import Testing
import CryptoKit
import AVFoundation
@testable import LibroxChatterbox

private func voiceFixture(at url: URL) throws {
    var payload = Data(), header: [String: Any] = [:]
    for (key, shape, integer) in [
        ("gen.embedding", [192], false), ("gen.prompt_feat", [4, 80], false),
        ("gen.prompt_token", [2], true), ("gen.prompt_token_len", [1], true),
        ("t3.cond_prompt_speech_tokens", [4], true), ("t3.speaker_emb", [256], false)
    ] {
        let start = payload.count
        for _ in 0..<shape.reduce(1, *) {
            var bits = (integer ? UInt32(key == "gen.prompt_token_len" ? 2 : 1) : Float(0.25).bitPattern).littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        }
        header[key] = ["dtype": integer ? "I32" : "F32", "shape": shape, "data_offsets": [start, payload.count]]
    }
    var json = try JSONSerialization.data(withJSONObject: header, options: .sortedKeys)
    while json.count % 8 != 0 { json.append(32) }
    var length = UInt64(json.count).littleEndian
    var data = withUnsafeBytes(of: &length) { Data($0) }
    data.append(json); data.append(payload)
    try data.write(to: url)
}

@Test func voiceStoreSurvivesRestartAndRejectsCorruption() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source.safetensors")
    try voiceFixture(at: source)
    let store = try ChatterboxVoiceStore(directory: temp.appendingPathComponent("voices"))
    let voice = try await store.save(name: "My narrator", language: "es", conditioningFile: source,
        origin: .ownRecording, referenceSHA256: String(repeating: "a", count: 64), referenceSeconds: 12, listeningAccepted: true)
    let reopened = try ChatterboxVoiceStore(directory: temp.appendingPathComponent("voices"))
    #expect(try await reopened.voices() == [voice])
    let file = try await reopened.conditioningFile(for: voice.id)
    let renamed = try await reopened.rename(voice.id, name: "My Spanish Voice")
    #expect(renamed.id == voice.id && renamed.conditioningSHA256 == voice.conditioningSHA256)
    #expect(renamed.name == "My Spanish Voice")
    #expect(try Data(contentsOf: file) == Data(contentsOf: source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).sorted()
            == ["conditioning.safetensors", "voice.json"])
    await #expect(throws: ChatterboxVoiceStore.StoreError.incompatibleModel) {
        _ = try await reopened.conditioningFile(for: voice.id, modelFamily: "other-model")
    }
    var changed = try Data(contentsOf: file); changed[changed.count - 1] ^= 1; try changed.write(to: file)
    await #expect(throws: ChatterboxVoiceStore.StoreError.damagedVoice) { _ = try await reopened.voice(voice.id) }
}

@Test func voiceStoreRejectsJunkWithoutSavingAndSupportsDelete() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let source = temp.appendingPathComponent("source.safetensors")
    try Data(repeating: 0, count: 16).write(to: source)
    let store = try ChatterboxVoiceStore(directory: temp.appendingPathComponent("voices"))
    await #expect(throws: (any Error).self) {
        _ = try await store.save(name: "Bad", language: "en", conditioningFile: source,
            origin: .ownRecording, referenceSHA256: String(repeating: "b", count: 64), referenceSeconds: 10, listeningAccepted: true)
    }
    #expect(try await store.voices().isEmpty)
    try voiceFixture(at: source)
    let voice = try await store.save(name: "Good", language: "en", conditioningFile: source,
        origin: .ownRecording, referenceSHA256: String(repeating: "b", count: 64), referenceSeconds: 10, listeningAccepted: true)
    try await store.delete(voice.id)
    #expect(try await store.voices().isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func recordingChecksRejectSilenceClippingAndShortAudio() {
    #expect(!ChatterboxRecordingQuality.analyze(samples: Array(repeating: 0, count: 8 * 24_000), sampleRate: 24_000).accepted)
    #expect(ChatterboxRecordingQuality.analyze(samples: Array(repeating: 1, count: 8 * 24_000), sampleRate: 24_000).issues.contains(.clipping))
    #expect(ChatterboxRecordingQuality.analyze(samples: Array(repeating: 0.1, count: 24_000), sampleRate: 24_000).issues.contains(.tooShort))
    let samples = (0..<(10 * 24_000)).map { Float(sin(Double($0) * .pi / 20)) * 0.1 }
    #expect(ChatterboxRecordingQuality.analyze(samples: samples, sampleRate: 24_000).accepted)
}

private func recordingFixture(at url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000)!
    buffer.frameLength = 240_000
    for i in 0..<240_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * .pi / 20)) * 0.1 }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

@Test func createVoicePreviewsThenSavesWithoutRetainingRecording() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let recording = temp.appendingPathComponent("original.caf"); try recordingFixture(at: recording)
    let store = try ChatterboxVoiceStore(directory: temp.appendingPathComponent("voices"))
    let creation = try ChatterboxVoiceCreation(directory: temp.appendingPathComponent("drafts"), store: store) { _, output in
        try voiceFixture(at: output)
    }
    await #expect(throws: ChatterboxVoiceCreation.CreationError.self) {
        _ = try await creation.prepare(recording: recording, language: "es", useMyRecording: false)
    }
    let draft = try await creation.prepare(recording: recording, language: "es", useMyRecording: true)
    #expect(try await store.voices().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: draft.conditioningFile.deletingLastPathComponent().path)
            == ["conditioning.safetensors"])
    await #expect(throws: ChatterboxVoiceCreation.CreationError.self) {
        _ = try await creation.prepare(recording: recording, language: "es", useMyRecording: true)
    }
    let saved = try await creation.saveAccepted(draft.id, name: "My Voice")
    #expect(saved.origin == .ownRecording)
    #expect(saved.listeningAccepted)
    #expect(!FileManager.default.fileExists(atPath: draft.conditioningFile.path))
    #expect(FileManager.default.fileExists(atPath: recording.path))
    #expect(try await store.voices() == [saved])
}

@Test func cancelledVoiceCreationCleansOnlyItsDraftAndSavesNothing() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let recording = temp.appendingPathComponent("original.caf"); try recordingFixture(at: recording)
    let store = try ChatterboxVoiceStore(directory: temp.appendingPathComponent("voices"))
    let creation = try ChatterboxVoiceCreation(directory: temp.appendingPathComponent("drafts"), store: store) { _, output in
        try await Task.sleep(for: .seconds(10)); try voiceFixture(at: output)
    }
    let work = Task { try await creation.prepare(recording: recording, language: "en", useMyRecording: true) }
    try await Task.sleep(for: .milliseconds(20)); work.cancel()
    do { _ = try await work.value; Issue.record("Expected cancellation") } catch is CancellationError {} catch { Issue.record("\(error)") }
    #expect(try await store.voices().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.appendingPathComponent("drafts").path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: recording.path))
}
