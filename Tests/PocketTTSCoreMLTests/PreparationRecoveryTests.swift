import Foundation
import CryptoKit
import XCTest
@testable import PocketTTSCoreML

final class PreparationRecoveryTests: XCTestCase {
    private struct Receipt: Codable { let source: String; let os: String; let hash: String }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fixture(_ root: URL, _ name: String, byte: UInt8 = 1, os: String = "current") throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(repeating: byte, count: 128)
        try data.write(to: directory.appendingPathComponent("weights"))
        try JSONEncoder().encode(Receipt(source: "pinned", os: os, hash: hash(data)))
            .write(to: directory.appendingPathComponent("receipt.json"), options: .atomic)
        return directory
    }
    private func validate(_ url: URL) throws {
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url.appendingPathComponent("receipt.json")))
        guard receipt.source == "pinned", receipt.os == "current",
              hash(try Data(contentsOf: url.appendingPathComponent("weights"))) == receipt.hash else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testCurrentWinsAndOnlyOwnedOrphansAreCleaned() throws {
        try withRoot { root in
            _ = try fixture(root, "compiled")
            _ = try fixture(root, "previous-" + UUID().uuidString)
            _ = try fixture(root, "compile-" + UUID().uuidString, byte: 2)
            let unrelated = try fixture(root, "compile-user-files")
            XCTAssertTrue(try PreparedModelTransaction(root: root).recover(validate: validate))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["compile-user-files", "compiled"])
        }
    }

    func testMissingOrSameSizeCorruptCurrentRecoversVerifiedBackup() throws {
        for corrupt in [false, true] {
            try withRoot { root in
                if corrupt {
                    let current = try fixture(root, "compiled")
                    try Data(repeating: 9, count: 128).write(to: current.appendingPathComponent("weights"))
                }
                _ = try fixture(root, "previous-" + UUID().uuidString, os: "wrong-os")
                _ = try fixture(root, "previous-" + UUID().uuidString, byte: 3)
                let transaction = PreparedModelTransaction(root: root)
                XCTAssertTrue(try transaction.recover(validate: validate))
                try validate(transaction.current)
                XCTAssertEqual(try Data(contentsOf: transaction.current.appendingPathComponent("weights")).first, 3)
            }
        }
    }

    func testCompleteStagingCanRecoverButPartialStagingCannotPublish() throws {
        try withRoot { root in
            let partial = root.appendingPathComponent("compile-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            let transaction = PreparedModelTransaction(root: root)
            XCTAssertFalse(try transaction.recover(validate: validate))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            _ = try fixture(root, "compile-" + UUID().uuidString)
            XCTAssertTrue(try transaction.recover(validate: validate))
            try validate(transaction.current)
        }
    }

    func testFailuresBeforeAndAfterEveryPublicationRenameRemainRecoverable() throws {
        enum Failure: Error { case interrupted }
        for operation in 1...2 {
            for after in [false, true] {
                try withRoot { root in
                    _ = try fixture(root, "compiled")
                    let stage = try fixture(root, "compile-" + UUID().uuidString, byte: 2)
                    var transaction = PreparedModelTransaction(root: root)
                    var calls = 0
                    transaction.operations.move = { source, destination in
                        calls += 1
                        if calls == operation, !after { throw Failure.interrupted }
                        try FileManager.default.moveItem(at: source, to: destination)
                        if calls == operation, after { throw Failure.interrupted }
                    }
                    XCTAssertThrowsError(try transaction.publishValidated(stage))
                    try? FileManager.default.removeItem(at: stage) // caller's normal deferred cleanup
                    let reopened = PreparedModelTransaction(root: root)
                    XCTAssertTrue(try reopened.recover(validate: validate))
                    try validate(reopened.current)
                }
            }
        }
    }

    func testFailedRollbackAndCleanupLeaveRecoverableGenerations() throws {
        enum Failure: Error { case disk }
        try withRoot { root in
            _ = try fixture(root, "compiled")
            let stage = try fixture(root, "compile-" + UUID().uuidString, byte: 2)
            var transaction = PreparedModelTransaction(root: root)
            var moves = 0
            transaction.operations.move = { source, destination in
                moves += 1
                if moves > 1 { throw Failure.disk }
                try FileManager.default.moveItem(at: source, to: destination)
            }
            XCTAssertThrowsError(try transaction.publishValidated(stage))
            try FileManager.default.removeItem(at: stage)
            let orphan = try fixture(root, "compile-" + UUID().uuidString, os: "wrong-os")
            var reopened = PreparedModelTransaction(root: root)
            reopened.operations.remove = { _ in throw Failure.disk }
            XCTAssertTrue(try reopened.recover(validate: validate))
            try validate(reopened.current)
            XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    func testCancellationIsNotMisclassifiedAsInvalidReceipt() throws {
        try withRoot { root in
            _ = try fixture(root, "compiled")
            let backup = try fixture(root, "previous-" + UUID().uuidString)
            XCTAssertThrowsError(try PreparedModelTransaction(root: root).recover { _ in throw CancellationError() }) {
                XCTAssertTrue($0 is CancellationError)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    func testRealPreparedReceiptReopensWithoutRecompilation() throws {
        guard let path = ProcessInfo.processInfo.environment["LIBROX_08_POCKET_ASSETS"] else {
            throw XCTSkip("Requires a task-owned copy of verified Core ML assets")
        }
        let root = URL(fileURLWithPath: path)
        try PocketTTSCoreMLAssets.prepare(in: root, language: "en")
        let models = PocketTTSCoreMLAssets.modelDirectory(in: root, language: "en")
        let current = models.appendingPathComponent("compiled"), backup = models.appendingPathComponent("previous-" + UUID().uuidString)
        let receipt = current.appendingPathComponent("receipt.json")
        let inode = try FileManager.default.attributesOfItem(atPath: receipt.path)[.systemFileNumber] as? NSNumber
        try FileManager.default.moveItem(at: current, to: backup)
        defer {
            if !FileManager.default.fileExists(atPath: current.path) { try? FileManager.default.moveItem(at: backup, to: current) }
        }
        try PocketTTSCoreMLAssets.prepare(in: root, language: "en")
        try PocketTTSCoreMLAssets.validate(in: root, language: "en")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: receipt.path)[.systemFileNumber] as? NSNumber, inode)
    }
}
