#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import LibroxTTS

final class PublicationCrash10Tests: XCTestCase {
    func testRestartKeepsWholeInstalledBytesAcrossProcessExit() throws {
        for phase in 0..<3 {
            let root = URL.temporaryDirectory.appendingPathComponent("librox-publication-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:root) }
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/xcrun")
            process.arguments = ["xctest","-XCTest","KokoroKitTests.PublicationCrash10Tests/testCrashChild",Bundle(for:Self.self).bundleURL.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["LIBROX_PUBLICATION_ROOT":root.path,"LIBROX_PUBLICATION_PHASE":String(phase)],uniquingKeysWith:{_,new in new})
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,71)
            let target = root.appendingPathComponent("installed"), source = root.appendingPathComponent("source")
            XCTAssertEqual(try Data(contentsOf:target),Data([phase == 2 ? 2 : 1]))
            try VerifiedFilePublication().publish(source,to:target) { url in
                XCTAssertEqual(try Data(contentsOf:url),Data([2]))
            }
            XCTAssertEqual(try Data(contentsOf:target),Data([2]))
        }
    }
    func testCrashChild() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LIBROX_PUBLICATION_ROOT"],let value = env["LIBROX_PUBLICATION_PHASE"],let phase = Int(value) else { throw XCTSkip("Subprocess helper") }
        let root = URL(fileURLWithPath:path), target = root.appendingPathComponent("installed"), source = root.appendingPathComponent("source")
        try Data([1]).write(to:target); try Data([2]).write(to:source)
        var publication = VerifiedFilePublication()
        publication.operations.copy = { from,to in
            try FileManager.default.copyItem(at:from,to:to)
            if phase == 0 { _exit(71) }
        }
        publication.operations.adopt = { stage,target in
            if phase == 1 { _exit(71) }
            _ = try FileManager.default.replaceItemAt(target,withItemAt:stage,options:.usingNewMetadataOnly)
            _exit(71)
        }
        try publication.publish(source,to:target) { _ in }
        XCTFail("Did not exit at publication boundary")
    }
}
#endif
