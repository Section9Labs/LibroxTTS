#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import PocketTTSCoreML

final class PreparationCrash10Tests: XCTestCase {
    func testPublicationSurvivesProcessExitAtEveryRenameBoundary() throws {
        for phase in 0..<4 {
            let root = URL.temporaryDirectory.appendingPathComponent("librox-crash-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", "PocketTTSCoreMLTests.PreparationCrash10Tests/testCrashChild", Bundle(for: Self.self).bundleURL.path]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "LIBROX_CRASH_ROOT":root.path, "LIBROX_CRASH_PHASE":String(phase)
            ], uniquingKeysWith: { _, new in new })
            let log = root.appendingPathComponent("child.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle; process.standardError = handle
            try process.run(); process.waitUntilExit(); try handle.close()
            let childLog = String(decoding: try Data(contentsOf: log), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 71, childLog)
            let reopened = PreparedModelTransaction(root: root)
            XCTAssertTrue(try reopened.recover { url in
                let bytes = try Data(contentsOf: url.appendingPathComponent("weights"))
                let receipt = try Data(contentsOf: url.appendingPathComponent("receipt"))
                guard bytes == receipt, bytes == Data([1]) || bytes == Data([2]) else { throw CocoaError(.fileReadCorruptFile) }
            })
            XCTAssertEqual(try Data(contentsOf: reopened.current.appendingPathComponent("weights")), Data([phase == 3 ? 2 : 1]))
        }
    }
    func testCrashChild() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LIBROX_CRASH_ROOT"], let phaseText = env["LIBROX_CRASH_PHASE"], let phase = Int(phaseText) else { throw XCTSkip("Subprocess helper") }
        let root = URL(fileURLWithPath:path), stage = root.appendingPathComponent("compile-" + UUID().uuidString)
        for (url, byte) in [(root.appendingPathComponent("compiled"),UInt8(1)),(stage,UInt8(2))] {
            try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
            try Data([byte]).write(to:url.appendingPathComponent("weights"))
            try Data([byte]).write(to:url.appendingPathComponent("receipt"))
        }
        var transaction = PreparedModelTransaction(root:root), calls = 0
        transaction.operations.move = { source, destination in
            let index = calls; calls += 1
            if phase == index * 2 { _exit(71) }
            try FileManager.default.moveItem(at:source,to:destination)
            if phase == index * 2 + 1 { _exit(71) }
        }
        try transaction.publishValidated(stage)
        XCTFail("Did not reach crash point")
    }
}
#endif
