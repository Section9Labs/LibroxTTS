#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit
import BackgroundTasks
import Synchronization

/// A real iOS 26+ background-GPU grant, never inferred from OS version alone.
/// The host requests this in response to a foreground user action and supplies
/// the Background GPU Access entitlement and permitted task identifier pattern.
/// Older iOS and unavailable/denied grants use `.background` CPU execution.
@available(iOS 26.0, *)
@MainActor public final class NarrationBackgroundGPUGrant {
    public enum GrantError: Error { case expired }
    private final class Gate: Sendable {
        struct State {
            var valid = true
            var cancellation: (@Sendable () -> Void)?
        }
        let state = Mutex(State())
        var valid: Bool { state.withLock { $0.valid } }
        func install(_ cancellation: @escaping @Sendable () -> Void) -> Bool {
            state.withLock { value in
                guard value.valid else { return false }
                value.cancellation = cancellation
                return true
            }
        }
        func clear() { state.withLock { $0.cancellation = nil } }
        func expire() {
            let cancel = state.withLock { value in
                value.valid = false
                let cancel = value.cancellation
                value.cancellation = nil
                return cancel
            }
            cancel?()
        }
    }
    private let task: BGContinuedProcessingTask
    private let gate = Gate()
    private var finished = false
    private var running = false
    private var retireWork: (() async -> Void)?
    public var isValid: Bool { !finished && gate.valid }
    public static var isSupported: Bool { BGTaskScheduler.supportedResources.contains(.gpu) }

    private init(task: BGContinuedProcessingTask, totalUnitCount: Int64) {
        self.task = task
        task.progress.totalUnitCount = max(1, totalUnitCount)
        let gate = self.gate
        // Cancellation is synchronous even if the UI/main actor is busy.
        task.expirationHandler = { gate.expire() }
    }

    /// Returns nil for unsupported hardware, denied/late grants or an inactive
    /// app. A successful submit is not treated as a grant: await the launch
    /// handler. Use a unique identifier under the app's permitted wildcard.
    public static func request(identifier: String, title: String, subtitle: String,
                               totalUnitCount: Int64) async throws -> NarrationBackgroundGPUGrant? {
        try Task.checkCancellation()
        guard UIApplication.shared.applicationState == .active, isSupported else { return nil }
        let pending = PendingGrant(identifier: identifier)
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.continuation = continuation
                let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                    MainActor.assumeIsolated {
                        guard let continued = task as? BGContinuedProcessingTask else {
                            task.setTaskCompleted(success: false); pending.resolve(nil); return
                        }
                        guard pending.continuation != nil else { continued.setTaskCompleted(success: false); return }
                        pending.resolve(NarrationBackgroundGPUGrant(task: continued, totalUnitCount: totalUnitCount))
                    }
                }
                guard registered else { pending.resolve(nil); return }
                let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
                request.requiredResources = .gpu
                request.strategy = .fail
                do { try BGTaskScheduler.shared.submit(request) }
                catch { pending.resolve(nil); return }
                // A late callback cannot upgrade a CPU render already in flight.
                pending.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(5)) }
                    catch { return }
                    pending.cancel()
                }
            }
        } onCancel: {
            Task { @MainActor in pending.cancel() }
        }
        if Task.isCancelled { await value?.finish(success: false); throw CancellationError() }
        return value
    }

    /// Serialize work through a grant. Expiration cancels and awaits the GPU
    /// render before throwing `.expired`; discard partial output, then retry the
    /// unfinished unit on CPU if playback is still requested. Parent task
    /// cancellation remains CancellationError and must never restart playback.
    public func withGPUWork<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard isValid, !running else { throw GrantError.expired }
        running = true
        let work = Task { try await operation() }
        retireWork = { _ = await work.result }
        guard gate.install({ work.cancel() }) else {
            work.cancel(); _ = await work.result; running = false; retireWork = nil
            throw GrantError.expired
        }
        defer { gate.clear(); running = false; retireWork = nil }
        do {
            let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard isValid else { throw GrantError.expired }
            return result
        } catch {
            try Task.checkCancellation()
            if !isValid { throw GrantError.expired }
            throw error
        }
    }

    public func reportProgress(completedUnitCount: Int64, subtitle: String? = nil) {
        guard isValid else { return }
        task.progress.completedUnitCount = min(task.progress.totalUnitCount, max(0, completedUnitCount))
        if let subtitle { task.updateTitle(task.title, subtitle: subtitle) }
    }

    /// Call after awaiting all work, including cancellation, on every exit path.
    public func finish(success: Bool) async {
        guard !finished else { return }
        finished = true; gate.expire()
        if let retireWork { await retireWork() }
        task.setTaskCompleted(success: success)
    }

    @MainActor private final class PendingGrant {
        let identifier: String
        var continuation: CheckedContinuation<NarrationBackgroundGPUGrant?, Never>?
        var timeout: Task<Void, Never>?
        init(identifier: String) { self.identifier = identifier }
        func resolve(_ grant: NarrationBackgroundGPUGrant?) {
            let continuation = continuation; self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation?.resume(returning: grant)
        }
        func cancel() {
            guard continuation != nil else { return }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            resolve(nil)
        }
    }
}
#endif
