import Foundation
import AVFoundation
import Combine

/// The host coordinates its existing listening audio session before recording,
/// and restores that session afterward. This recorder never changes its category.
@MainActor public final class ChatterboxVoiceRecorder: ObservableObject {
    public enum RecorderError: Error { case permissionDenied, busy, unableToRecord }
    @Published public private(set) var isRecording = false
    private let directory: URL
    private let activate: @MainActor () throws -> Void
    private let restore: @MainActor () -> Void
    private var recorder: AVAudioRecorder?
    private var delegate: RecordingDelegate?
    private var continuation: CheckedContinuation<URL, Error>?
    private var currentID: UUID?
    private var output: URL?

    public init(directory: URL, activateRecordingSession: @escaping @MainActor () throws -> Void,
                restoreListeningSession: @escaping @MainActor () -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        self.directory = directory; activate = activateRecordingSession; restore = restoreListeningSession
    }

    public func record() async throws -> URL {
        guard currentID == nil else { throw RecorderError.busy }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.permissionDenied }
        try Task.checkCancellation()
        guard currentID == nil else { throw RecorderError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion in
                continuation = completion; currentID = id
                let file = directory.appendingPathComponent(id.uuidString + ".caf")
                output = file
                do {
                    try activate()
                    let value = try AVAudioRecorder(url: file, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false])
                    let callbacks = RecordingDelegate { [weak self] success in
                        Task { @MainActor in self?.finish(id: id, success: success) }
                    }
                    delegate = callbacks; value.delegate = callbacks; recorder = value
                    guard value.record(forDuration: 20) else { throw RecorderError.unableToRecord }
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    isRecording = true
                    if Task.isCancelled { cancel(id: id) }
                } catch { finish(id: id, success: false, error: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    public func stop() { if let id = currentID { recorder?.stop(); finish(id: id, success: true) } }
    public func cancel() { if let id = currentID { cancel(id: id) } }
    private func cancel(id: UUID) {
        guard currentID == id else { return }
        recorder?.stop(); finish(id: id, success: false, error: CancellationError())
    }
    private func finish(id: UUID, success: Bool, error: Error? = nil) {
        guard currentID == id else { return }
        let completion = continuation, file = output
        recorder = nil; delegate = nil; continuation = nil; currentID = nil; output = nil; isRecording = false
        restore()
        if success, let file { completion?.resume(returning: file) }
        else {
            if let file { try? FileManager.default.removeItem(at: file) }
            completion?.resume(throwing: error ?? RecorderError.unableToRecord)
        }
    }
}

private final class RecordingDelegate: NSObject, AVAudioRecorderDelegate {
    private let completed: @Sendable (Bool) -> Void
    init(completed: @escaping @Sendable (Bool) -> Void) { self.completed = completed }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { completed(flag) }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) { completed(false) }
}
