#if os(macOS)
import XCTest
import Foundation
@testable import LibroxChatterboxMLX

final class ReferenceOwnedChildTests: XCTestCase {
    private struct Outcome: Sendable { let cancelled: Bool, running: Bool, killed: Bool }
    private func exercise(ignoreTerm: Bool) async throws {
        guard let python = ProcessInfo.processInfo.environment["REFERENCE_TEST_PYTHON"],
            FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("Set REFERENCE_TEST_PYTHON for owned worker checks") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let outcome = await Task { () -> Outcome in
            let child = Process(), owner = ReferenceOwnedChild()
            child.executableURL = URL(fileURLWithPath: python)
            let handler = ignoreTerm ? "signal.signal(signal.SIGTERM, signal.SIG_IGN)" : "pass"
            child.arguments = ["-c", "import pathlib,signal,sys,time; \(handler); pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(30)", ready.path]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            let start = Date()
            do {
                _ = try owner.run(child) {
                    if FileManager.default.fileExists(atPath: ready.path) { withUnsafeCurrentTask { $0?.cancel() } }
                    try Task.checkCancellation()
                    if Date().timeIntervalSince(start) > 10 { throw NSError(domain: "worker did not become ready", code: 1) }
                }
                return Outcome(cancelled: false, running: child.isRunning, killed: owner.usedSIGKILL)
            } catch { return Outcome(cancelled: error is CancellationError, running: child.isRunning, killed: owner.usedSIGKILL) }
        }.value
        XCTAssertTrue(outcome.cancelled)
        XCTAssertFalse(outcome.running)
        XCTAssertEqual(outcome.killed, ignoreTerm)
    }
    func testActualOwnedWorkerCancellationJoins() async throws { try await exercise(ignoreTerm: false) }
    func testActualIgnoredTermEscalatesAndJoins() async throws { try await exercise(ignoreTerm: true) }
}
#endif
