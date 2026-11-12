import CryptoKit
import Foundation
import Synchronization
import XCTest
import KokoroCatalog
@testable import LibroxTTS

final class VerifiedAssetTransferTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    func testReplacementKeepsOldFileAcrossCopyVerificationAndAdoptionFailures() throws {
        let root = try root(), source = root.appendingPathComponent("source"), target = root.appendingPathComponent("installed")
        let old = Data("old-good".utf8), new = Data("new-good".utf8)
        try new.write(to:source)
        for fault in 0..<4 {
            try old.write(to:target)
            var publication = VerifiedFilePublication()
            if fault == 0 { publication.operations.copy = { _,stage in
                try Data("partial".utf8).write(to:stage)
                throw CocoaError(.fileWriteOutOfSpace)
            } }
            if fault == 1 { publication.operations.copy = { _,stage in try Data("bad-copy".utf8).write(to:stage) } }
            if fault == 2 { publication.operations.adopt = { _,_ in throw CocoaError(.fileWriteNoPermission) } }
            do {
                try publication.publish(source,to:target) { url in
                    guard try Data(contentsOf:url) == new else { throw CocoaError(.fileReadCorruptFile) }
                }
                XCTAssertEqual(fault,3)
            } catch { XCTAssertLessThan(fault,3) }
            XCTAssertEqual(try Data(contentsOf:target),fault == 3 ? new : old)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".download-")})
        }
    }
    func testCancellationAfterStagingNeverPublishes() async throws {
        let root = try root(), source = root.appendingPathComponent("source"), target = root.appendingPathComponent("installed")
        let old = Data("old".utf8)
        try old.write(to:target); try Data("new".utf8).write(to:source)
        let task = Task {
            try VerifiedFilePublication().publish(source,to:target) { _ in withUnsafeCurrentTask{$0?.cancel()} }
        }
        do { try await task.value; XCTFail("Cancelled publication succeeded") } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf:target),old)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".download-")})
    }
    func testTransferReusesVerifiedFilesPreservesProgressAndRejectsSameSizeCorruption() async throws {
        let root = try root(), data = Data("new-good".utf8)
        let file: [String:Any] = ["path":"voice.bin","size":data.count,"sha256":hash(data),"sourceURL":"https://example.invalid/voice"]
        let manifest = try JSONDecoder().decode(AssetManifest.self,from:JSONSerialization.data(withJSONObject:["repository":"fixture","revision":"1","files":[file],"installedFiles":[file]]))
        let target = root.appendingPathComponent("voice.bin")
        try Data("bad-old!".utf8).write(to:target)
        let downloads = Mutex(0), progress = Mutex([Double]())
        var transfer = VerifiedAssetTransfer()
        transfer.download = { url in
            downloads.withLock{$0 += 1}
            let temp = root.appendingPathComponent("network-"+UUID().uuidString)
            try data.write(to:temp)
            return (temp,HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        for _ in 0..<2 {
            try await transfer.run(manifest,to:root,matches:{ try NarrationAssets.matches($0,size:$1.size,sha256:$1.sha256) },
                invalid:{ _ in CocoaError(.fileReadCorruptFile) },progress:{ value in progress.withLock{$0.append(value)} })
        }
        XCTAssertEqual(downloads.withLock{$0},1); XCTAssertEqual(progress.withLock{$0},[1,1])
        XCTAssertEqual(try Data(contentsOf:target),data)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix("network-")})
    }
    func testBadHTTPAndChecksumCannotReplaceInstalledBytes() async throws {
        let root = try root(), old = Data("old".utf8), expected = Data("new".utf8)
        let file:[String:Any] = ["path":"voice.bin","size":3,"sha256":hash(expected),"sourceURL":"https://example.invalid/voice"]
        let manifest = try JSONDecoder().decode(AssetManifest.self,from:JSONSerialization.data(withJSONObject:["repository":"fixture","revision":"1","files":[file],"installedFiles":[file]]))
        let target = root.appendingPathComponent("voice.bin"); try old.write(to:target)
        for status in [503,200] {
            var transfer = VerifiedAssetTransfer()
            transfer.download = { url in
                let temp = root.appendingPathComponent(UUID().uuidString); try Data("bad".utf8).write(to:temp)
                return (temp,HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!)
            }
            do {
                try await transfer.run(manifest,to:root,matches:{ try NarrationAssets.matches($0,size:$1.size,sha256:$1.sha256) },invalid:{_ in CocoaError(.fileReadCorruptFile)},progress:{_ in XCTFail("Failed file advanced progress")})
                XCTFail("Invalid download succeeded")
            } catch {
                if status == 503 { XCTAssertEqual((error as? URLError)?.code,.badServerResponse) }
                else { XCTAssertEqual((error as? CocoaError)?.code,.fileReadCorruptFile) }
            }
            XCTAssertEqual(try Data(contentsOf:target),old)
        }
    }
}
