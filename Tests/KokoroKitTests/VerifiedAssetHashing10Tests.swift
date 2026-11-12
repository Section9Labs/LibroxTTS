import CryptoKit
import Foundation
import XCTest
@testable import KokoroCatalog

final class VerifiedAssetHashing10Tests: XCTestCase {
    func testFullHashesFirstErrorAndSizePolicies() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let data = Data(repeating: 17, count: 2_097_155)
        let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        var files: [VerifiedAssetHashing.File] = []
        for i in 0..<9 {
            let url = root.appendingPathComponent(String(i)); try data.write(to:url)
            files.append(.init(url:url,size:data.count,sha256:hash))
        }
        try VerifiedAssetHashing.validate(files)
        // Same-size damage must fail even after a successful earlier call.
        try Data(repeating:18,count:data.count).write(to:files[1].url)
        try FileManager.default.removeItem(at:files[2].url)
        XCTAssertThrowsError(try VerifiedAssetHashing.validate(files)) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue)
        }
        try data.write(to:files[1].url)
        XCTAssertThrowsError(try VerifiedAssetHashing.validate(files)) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileNoSuchFile.rawValue)
        }
    }
    func testCancelledCallDoesNotStartValidation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try VerifiedAssetHashing.validate([.init(url:URL(fileURLWithPath:"/missing"),sha256:"")])) { error in
                XCTAssertTrue(error is CancellationError)
            }
        }
        try await task.value
    }
}
