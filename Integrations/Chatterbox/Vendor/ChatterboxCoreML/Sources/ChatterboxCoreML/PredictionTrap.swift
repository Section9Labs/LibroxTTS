import ChatterboxExceptionTrap
import CoreML
import Foundation

/// Runs `body`, converting an Objective-C `NSException` into a Swift
/// ``ChatterboxError/prediction(_:_:)`` so an accelerator fault fails the *utterance*
/// instead of the *process*.
///
/// `MLModel.prediction(from:)` reports most failures as `NSError` (a plain Swift
/// `throws`), but some accelerator faults are `@throw`n as an `NSException` — which
/// Swift cannot catch, so it unwinds past every `do/catch` into `std::terminate`.
/// That is how a Neural Engine `E5RT: No memory object bound to port` killed the app
/// on device (2026-07-26; the input shape that provoked it is now fenced off by
/// `Constants.maxVocoderTokens`, but nothing else guards the general case).
/// ``CBXPerformTrappingExceptions`` is the package's one Objective-C file, existing
/// purely to put an `@try/@catch` in the path — see its header for the caveat on
/// trapping framework exceptions.
///
/// A Swift error thrown by `body` propagates unchanged; only an `NSException` is
/// converted. `label` names the stage in the thrown error so a device log says which
/// model faulted.
func trapping<T>(_ label: String, _ body: () throws -> T) throws -> T {
    // Core ML calls are synchronous and cannot be interrupted here. Do not start
    // one for a cancelled request, and stop at its return before more host work.
    try Task.checkCancellation()
    var outcome: Result<T, any Error>?
    var trapped: NSError?
    let completed = CBXPerformTrappingExceptions({ outcome = Result { try body() } }, &trapped)

    guard completed else {
        throw ChatterboxError.prediction(
            label, trapped?.localizedDescription ?? "unknown Objective-C exception")
    }
    guard let outcome else {
        // Unreachable: the block ran to completion, so it assigned.
        throw ChatterboxError.prediction(label, "produced no result")
    }
    let result = try outcome.get()
    try Task.checkCancellation()
    return result
}

/// One CoreML prediction, run under ``trapping(_:_:)``. `body` defaults to the plain
/// stateless `prediction(from:)`; the T3LM runners pass the stateful
/// `prediction(from:using:options:)` variant.
func predictTrapping(
    _ model: MLModel,
    from provider: some MLFeatureProvider,
    label: String,
    body: (MLModel, any MLFeatureProvider) throws -> any MLFeatureProvider = { try $0.prediction(from: $1) }
) throws -> any MLFeatureProvider {
    try trapping(label) { try body(model, provider) }
}
