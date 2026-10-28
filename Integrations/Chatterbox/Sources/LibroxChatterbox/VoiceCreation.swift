import Foundation
import AVFoundation
import CryptoKit
import ChatterboxCoreML

public struct ChatterboxRecordingQuality: Sendable, Equatable {
    public enum Issue: String, Sendable { case tooShort, tooLong, tooQuiet, clipping, littleActivity, invalidAudio }
    public let seconds: Double
    public let rms: Double
    public let peak: Float
    public let issues: [Issue]
    public var accepted: Bool { issues.isEmpty }

    /// Signal checks only; does not establish words, identity or voice similarity.
    public static func analyze(samples: [Float], sampleRate: Double) -> Self {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate), !samples.isEmpty,
              samples.allSatisfy(\.isFinite) else {
            return .init(seconds: 0, rms: 0, peak: 0, issues: [.invalidAudio])
        }
        let seconds = Double(samples.count) / sampleRate
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let clipped = Double(samples.filter { abs($0) >= 0.999 }.count) / Double(samples.count)
        let hop = max(1, Int(sampleRate / 50))
        var active = 0, frames = 0
        for start in stride(from: 0, to: samples.count, by: hop) {
            let end = min(samples.count, start + hop)
            let energy = samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
            if sqrt(energy / Double(end - start)) >= max(0.005, rms * 0.2) { active += 1 }
            frames += 1
        }
        var issues: [Issue] = []
        if seconds < 6 { issues.append(.tooShort) }
        if seconds > 20 { issues.append(.tooLong) }
        if rms < 0.003 { issues.append(.tooQuiet) }
        if clipped > 0.001 { issues.append(.clipping) }
        if Double(active) / Double(max(1, frames)) < 0.35 { issues.append(.littleActivity) }
        return .init(seconds: seconds, rms: rms, peak: peak, issues: issues)
    }
}

public struct ChatterboxVoiceDraft: Sendable, Identifiable {
    public let id: UUID
    public let language: String
    public let conditioningFile: URL
    public let referenceSHA256: String
    public let quality: ChatterboxRecordingQuality
}

/// Record in the host, prepare and audition locally, then explicitly save.
/// Owns only its UUID draft folders; never owns the microphone or audio session.
public actor ChatterboxVoiceCreation {
    public enum CreationError: Error { case busy, consentRequired, rejectedRecording(ChatterboxRecordingQuality), staleDraft }
    public typealias Encoder = @Sendable (_ recording: URL, _ conditioningOutput: URL) async throws -> Void
    private let directory: URL
    private let store: ChatterboxVoiceStore
    private let encoder: Encoder
    private var draft: ChatterboxVoiceDraft?
    private var occupied = false

    public init(directory: URL, store: ChatterboxVoiceStore, encoder: @escaping Encoder) throws {
        guard directory.isFileURL else { throw ChatterboxVoiceStore.StoreError.unsafePath }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
        else { throw ChatterboxVoiceStore.StoreError.unsafePath }
        self.directory = directory; self.store = store; self.encoder = encoder
    }

    public static func local(directory: URL, store: ChatterboxVoiceStore, modelsDirectory: URL,
                             computePolicy: ChatterboxNarrator.ComputePolicy = .automatic) throws -> ChatterboxVoiceCreation {
        try .init(directory: directory, store: store) { recording, output in
            try await ChatterboxNarrator().prepareReference(audioFile: recording,
                modelsDirectory: modelsDirectory, outputFile: output, computePolicy: computePolicy)
        }
    }

    public static func readingPrompt(language: String) -> String {
        language == "es"
            ? "Esta es mi voz. Hoy voy a contar una historia. La mañana estaba tranquila, pero al abrir la puerta encontré una sorpresa. ¡Qué alegría volver a verte! Respira. Todo va a salir bien."
            : "This is my voice. Today I am going to tell a story. The morning was quiet, but when I opened the door, a surprise was waiting. I am so glad you came back! Take a breath. Everything will be all right."
    }

    public func prepare(recording: URL, language: String, useMyRecording: Bool) async throws -> ChatterboxVoiceDraft {
        guard !occupied, draft == nil else { throw CreationError.busy }
        guard useMyRecording else { throw CreationError.consentRequired }
        guard ChatterboxRequest.languages.contains(language) else { throw ChatterboxNarrationError.unsupportedLanguage(language) }
        occupied = true; defer { occupied = false }
        try Task.checkCancellation()
        let audio = try AVAudioFile(forReading: recording)
        let sr = audio.processingFormat.sampleRate
        guard (8_000...192_000).contains(sr), audio.length > 0,
              Double(audio.length) / sr <= 20, (1...2).contains(audio.processingFormat.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))
        else { throw ChatterboxNarrationError.invalidAudio }
        try audio.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw ChatterboxNarrationError.invalidAudio }
        let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        let samples = (0..<count).map { frame in (0..<channelCount).reduce(Float.zero) { $0 + channels[$1][frame] } / Float(channelCount) }
        let quality = ChatterboxRecordingQuality.analyze(samples: samples, sampleRate: sr)
        guard quality.accepted else { throw CreationError.rejectedRecording(quality) }
        let id = UUID(), folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var ready = false
        defer { if !ready { try? FileManager.default.removeItem(at: folder) } }
        // Snapshot the accepted signal so a caller cannot swap the file while encoding.
        let snapshot = folder.appendingPathComponent("recording.caf")
        do {
            let writer = try AVAudioFile(forWriting: snapshot, settings: buffer.format.settings)
            try writer.write(from: buffer)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
        let referenceHash = Self.hash(try Data(contentsOf: snapshot))
        let conditioning = folder.appendingPathComponent("conditioning.safetensors")
        try await encoder(snapshot, conditioning)
        try Task.checkCancellation()
        try ChatterboxVoiceFile.validate(at: conditioning)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: conditioning.path)
        // Keep only derived conditioning after preparation; original belongs to host.
        try FileManager.default.removeItem(at: snapshot)
        let value = ChatterboxVoiceDraft(id: id, language: language, conditioningFile: conditioning,
                                        referenceSHA256: referenceHash, quality: quality)
        draft = value; ready = true
        return value
    }

    public func saveAccepted(_ id: UUID, name: String) async throws -> ChatterboxSavedVoice {
        guard !occupied else { throw CreationError.busy }
        guard let value = draft, value.id == id else { throw CreationError.staleDraft }
        try Task.checkCancellation()
        occupied = true; defer { occupied = false }
        let voice = try await store.save(name: name, language: value.language,
            conditioningFile: value.conditioningFile, origin: .ownRecording,
            referenceSHA256: value.referenceSHA256, referenceSeconds: value.quality.seconds, listeningAccepted: true)
        // The profile has committed. A temporary-file cleanup failure must not
        // report saving as failed or encourage a duplicate retry.
        draft = nil
        try? remove(value)
        return voice
    }

    public func discard() throws {
        guard !occupied else { throw CreationError.busy }
        if let draft { try remove(draft); self.draft = nil }
    }
    public func discard(_ id: UUID) throws {
        guard !occupied else { throw CreationError.busy }
        guard let value = draft, value.id == id else { throw CreationError.staleDraft }
        try remove(value); draft = nil
    }
    private func remove(_ value: ChatterboxVoiceDraft) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(value.id.uuidString, isDirectory: true))
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
