import SwiftUI
import AVFoundation
import LibroxChatterbox

/// Native recording -> quality check -> generated preview -> named saved voice.
/// The host supplies preview rendering and audio-session coordination.
@MainActor public struct ChatterboxCreateVoiceSheet: View {
    private enum Stage { case ready, recording, preparing, preview, saving, saved }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var recorder: ChatterboxVoiceRecorder
    private let creation: ChatterboxVoiceCreation
    private let language: String
    /// Writes the preview to the supplied draft-owned output. The draft service
    /// removes it on acceptance/discard; the callback must not return shared PCM.
    private let makePreview: @Sendable (ChatterboxVoiceDraft, URL) async throws -> Void
    private let activatePreview: @MainActor () throws -> Void
    private let restoreSession: @MainActor () -> Void
    private let onSaved: @MainActor (ChatterboxSavedVoice) -> Void
    @State private var stage = Stage.ready
    @State private var useRecording = false
    @State private var voiceName = "My Voice"
    @State private var draft: ChatterboxVoiceDraft?
    @State private var player: AVAudioPlayer?
    @State private var task: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var dismissed = false
    @State private var previewPlayed = false
    @State private var previewActive = false
    @State private var playbackID: UUID?
    @State private var previewDelegate: VoicePreviewDelegate?
    @State private var suspending = false

    public init(recorder: ChatterboxVoiceRecorder, creation: ChatterboxVoiceCreation, language: String,
                makePreview: @escaping @Sendable (ChatterboxVoiceDraft, URL) async throws -> Void,
                activatePreviewSession: @escaping @MainActor () throws -> Void,
                restoreListeningSession: @escaping @MainActor () -> Void,
                onSaved: @escaping @MainActor (ChatterboxSavedVoice) -> Void) {
        self.recorder = recorder; self.creation = creation; self.language = language; self.makePreview = makePreview
        activatePreview = activatePreviewSession; restoreSession = restoreListeningSession; self.onSaved = onSaved
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Read at your normal pace in a quiet room. Stop when you finish; aim for 10–15 seconds.")
                    Text(ChatterboxVoiceCreation.readingPrompt(language: language)).font(.title3).textSelection(.enabled)
                } header: { Text("Read This Aloud") }
                if stage == .ready {
                    Toggle("Use my recording to create a saved voice on this device", isOn: $useRecording)
                    Button("Record My Voice", systemImage: "mic.fill") { start() }.disabled(!useRecording)
                } else if stage == .recording {
                    Label("Recording…", systemImage: "record.circle.fill").foregroundStyle(.red)
                    Button("Stop Recording", systemImage: "stop.fill") { recorder.stop() }
                } else if stage == .preparing {
                    ProgressView("Creating your voice preview…")
                } else if stage == .preview {
                    TextField("Voice Name", text: $voiceName)
                    Button("Play Preview", systemImage: "play.fill") { playPreview() }
                    Text("Listen to the preview, then save if it sounds right.")
                    Button("Save Voice", systemImage: "checkmark") { save() }
                        .disabled(!previewPlayed || voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Record Again") { reset() }
                } else if stage == .saving {
                    ProgressView("Saving your voice…")
                } else {
                    Label("Voice Saved", systemImage: "checkmark.circle.fill")
                    Text("You can now choose this voice for narration.")
                    Button("Done") { dismiss() }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).accessibilityLabel("Recording issue: " + errorMessage) }
            }
            .navigationTitle("Create Your Voice")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismissed = true; cancel(); dismiss() }.disabled(stage == .saving) } }
        }
        .onDisappear { dismissed = true; cancel() }
        .onChange(of: scenePhase) { _, value in
            if value == .background || (value == .inactive && stage == .preparing) { suspend() }
        }
    }

    private func start() {
        guard stage == .ready, !dismissed, !suspending else { return }
        errorMessage = nil; stage = .recording
        task = Task {
            var recording: URL?
            var preparedID: UUID?
            defer { if let recording { try? FileManager.default.removeItem(at: recording) } }
            do {
                let file = try await recorder.record(); recording = file
                try Task.checkCancellation(); stage = .preparing
                let value = try await creation.prepare(recording: file, language: language, useMyRecording: useRecording)
                preparedID = value.id
                draft = value
                try Task.checkCancellation()
                let preview = value.conditioningFile.deletingLastPathComponent().appendingPathComponent("preview.wav")
                try await makePreview(value, preview)
                try Task.checkCancellation()
                let properties = try preview.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                      (properties.fileSize ?? .max) <= 10 * 1_024 * 1_024 else { throw ChatterboxNarrationError.invalidAudio }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preview.path)
                player = try AVAudioPlayer(contentsOf: preview); previewPlayed = false; stage = .preview
            } catch is CancellationError {
                stage = .preparing
                if let preparedID { try? await creation.discard(preparedID) }
                if draft?.id == preparedID { draft = nil }
                stage = .ready
            }
            catch {
                errorMessage = message(error); stage = .preparing
                if let preparedID { try? await creation.discard(preparedID) }
                if draft?.id == preparedID { draft = nil }
                stage = .ready
            }
        }
    }
    private func save() {
        guard let draft else { return }
        stopPreview(); stage = .saving
        task = Task {
            do {
                let value = try await creation.saveAccepted(draft.id, name: voiceName)
                self.draft = nil; stage = .saved
                if !dismissed { onSaved(value) }
            } catch {
                if dismissed { try? await creation.discard(draft.id); self.draft = nil }
                else { errorMessage = error.localizedDescription; stage = .preview }
            }
        }
    }
    private func reset() {
        stopPreview(); player = nil; previewPlayed = false
        let oldDraft = draft; stage = .preparing
        task = Task {
            do {
                if let oldDraft {
                    do { try await creation.discard(oldDraft.id) }
                    catch ChatterboxVoiceCreation.CreationError.staleDraft { /* Already discarded. */ }
                }
                draft = nil; stage = .ready
            } catch { errorMessage = error.localizedDescription; stage = .preview }
        }
    }
    private func cancel() {
        task?.cancel(); recorder.cancel(); stopPreview()
        if let draft { Task { try? await creation.discard(draft.id) } }
    }
    private func suspend() {
        guard !suspending else { return }
        // Saving crosses a short atomic disk commit; it has no microphone/GPU
        // work to stop and must retain its saved confirmation when returning.
        guard stage != .saving, stage != .saved else { stopPreview(); return }
        suspending = true
        let previous = task, oldDraft = draft
        previous?.cancel(); recorder.cancel(); stopPreview()
        player = nil; previewPlayed = false; stage = .preparing
        task = Task {
            defer { suspending = false }
            await previous?.value
            if let oldDraft { try? await creation.discard(oldDraft.id) }
            draft = nil; errorMessage = nil; stage = .ready
        }
    }
    private func playPreview() {
        do {
            if !previewActive { try activatePreview(); previewActive = true }
            let id = UUID(); playbackID = id
            let callbacks = VoicePreviewDelegate { success in
                Task { @MainActor in
                    guard playbackID == id else { return }
                    previewPlayed = previewPlayed || success
                    stopPreview()
                }
            }
            previewDelegate = callbacks; player?.delegate = callbacks; player?.currentTime = 0
            guard player?.play() == true else { throw ChatterboxNarrationError.invalidAudio }
        } catch { stopPreview(); errorMessage = error.localizedDescription }
    }
    private func stopPreview() {
        playbackID = nil; player?.stop(); previewDelegate = nil
        if previewActive { previewActive = false; restoreSession() }
    }
    private func message(_ error: Error) -> String {
        if case ChatterboxVoiceCreation.CreationError.rejectedRecording(let report) = error {
            if report.issues.contains(.tooShort) { return "Record at least six seconds. Read the whole passage and try again." }
            if report.issues.contains(.clipping) { return "The recording is distorted. Move a little farther from the microphone and try again." }
            return "The recording is too quiet or contains too little sound. Move closer to the microphone and try again."
        }
        if case ChatterboxVoiceRecorder.RecorderError.permissionDenied = error { return "Allow microphone access in Settings, then try again." }
        return "Unable to create this voice. Check that the voice models are installed and try again."
    }
}

private final class VoicePreviewDelegate: NSObject, AVAudioPlayerDelegate {
    let completed: @Sendable (Bool) -> Void
    init(completed: @escaping @Sendable (Bool) -> Void) { self.completed = completed }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { completed(flag) }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { completed(false) }
}
