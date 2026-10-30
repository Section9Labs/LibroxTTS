#if os(macOS)
import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ChatterboxMacAcousticAudit

final class FileAudioExportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }
    private func pcm(_ url: URL, count: Int, bad: Float? = nil) throws -> String {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        var hash = SHA256()
        for start in stride(from: 0, to: count, by: 65536) {
            var data = Data(); data.reserveCapacity(min(65536, count - start) * 4)
            for i in start..<min(start + 65536, count) {
                let value = i == count - 1 ? (bad ?? Float(sin(Double(i) * 0.057595865)) * 0.45)
                    : Float(sin(Double(i) * 0.057595865)) * 0.45
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            try file.write(contentsOf: data); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func children(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
    func testLongALACAndAACAreStreamedWithExactGaplessFrames() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), frames = 3_100_001 // Beyond old120s bound, nonpacket-aligned.
        let hash = try pcm(raw, count: frames)
        let alac = try NativeFileAudioExport.write(rawPCM: raw, frames: Int64(frames), pcmSHA256: hash,
            to: dir.appendingPathComponent("lossless.m4a"), codec: .alac24)
        let aac = try NativeFileAudioExport.write(rawPCM: raw, frames: Int64(frames), pcmSHA256: hash,
            to: dir.appendingPathComponent("smaller.m4a"), codec: .aac64)
        for result in [alac, aac] {
            XCTAssertEqual(result.frames, Int64(frames)); XCTAssertTrue(result.frameCountMatches)
            XCTAssertLessThanOrEqual(try XCTUnwrap(result.decodedPeak), 1)
            let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        }
        XCTAssertEqual(alac.samplePrecisionChecked, true); XCTAssertEqual(aac.samplePrecisionChecked, false)
        XCTAssertLessThan(aac.bytes, alac.bytes)
        XCTAssertEqual(try children(dir), ["lossless.m4a", "smaller.m4a", "source.f32"])
        let rawHash = SHA256.hash(data: try Data(contentsOf: raw)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, rawHash)
    }
    func testWAVVariantsReadBackAndNeverReplaceDestination() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), hash = try pcm(raw, count: 144001)
        for (name, codec) in [("float.wav", NativeAudioExport.Codec.wavFloat32), ("integer.wav", .wavPCM16)] {
            let url = dir.appendingPathComponent(name)
            let result = try NativeFileAudioExport.write(rawPCM: raw, frames: 144001, pcmSHA256: hash, to: url, codec: codec)
            XCTAssertEqual(result.samplePrecisionChecked, true)
            let original = try Data(contentsOf: url)
            XCTAssertThrowsError(try NativeFileAudioExport.write(rawPCM: raw, frames: 144001, pcmSHA256: hash,
                to: url, codec: codec)) { XCTAssertEqual($0 as? NativeFileAudioExport.Failure, .destinationExists) }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
    func testHashAndInvalidSamplesNeverPublishAndCleanOnlyOwnedStaging() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), out = dir.appendingPathComponent("out.m4a")
        _ = try pcm(raw, count: 144001)
        XCTAssertThrowsError(try NativeFileAudioExport.write(rawPCM: raw, frames: 144001,
            pcmSHA256: String(repeating: "0", count: 64), to: out, codec: .aac64)) {
            XCTAssertEqual($0 as? NativeFileAudioExport.Failure, .sourceHash)
        }
        for value: Float in [.nan, .infinity, 1.001, -1.001] {
            let hash = try pcm(raw, count: 144001, bad: value)
            XCTAssertThrowsError(try NativeFileAudioExport.write(rawPCM: raw, frames: 144001,
                pcmSHA256: hash, to: out, codec: .aac64)) {
                XCTAssertEqual($0 as? NativeFileAudioExport.Failure, .input)
            }
            XCTAssertEqual(try children(dir), ["source.f32"])
        }
    }
    func testInputBoundsSymlinkFIFOAndWrongLengthRejectBeforeEncoding() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), hash = try pcm(raw, count: 100)
        let symbolic = dir.appendingPathComponent("link.f32"), fifo = dir.appendingPathComponent("fifo.f32")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: raw)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for (input, frames) in [(raw, Int64(99)), (symbolic, 100), (fifo, 100),
                                (raw, 0), (raw, NativeFileAudioExport.maximumFrames + 1)] {
            XCTAssertThrowsError(try NativeFileAudioExport.write(rawPCM: input, frames: frames,
                pcmSHA256: hash, to: dir.appendingPathComponent("out.m4a"), codec: .aac64))
        }
        XCTAssertEqual(try children(dir), ["fifo.f32", "link.f32", "source.f32"])
    }
    func testAACReconstructionOvershootIsTypedAndNeverPublished() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), out = dir.appendingPathComponent("out.m4a")
        // Deterministic in-range square wave, not model/audio fixture data.
        // Lossy transform reconstruction can exceed its source sample peaks.
        var bytes = Data()
        for i in 0..<48001 {
            var bits = Float(i % 240 < 120 ? 0.99 : -0.99).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        try bytes.write(to: raw)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try NativeFileAudioExport.write(rawPCM: raw, frames: 48001,
            pcmSHA256: hash, to: out, codec: .aac64)) { error in
            guard case let NativeFileAudioExport.Failure.decodedSampleRange(codec, index, value) = error else {
                return XCTFail("Wrong readback classification: \(error)")
            }
            XCTAssertEqual(codec, "AAC-LC-64k-requested"); XCTAssertGreaterThanOrEqual(index, 0)
            XCTAssertTrue(!value.isFinite || abs(value) > 1)
        }
        XCTAssertEqual(try Data(contentsOf: raw), bytes)
        XCTAssertEqual(try children(dir), ["source.f32"])
    }
    func testDestinationCreatedDuringEncodeCannotBeReplaced() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), hash = try pcm(raw, count: 144001)
        let out = dir.appendingPathComponent("out.m4a"), unrelated = Data("other completed job".utf8)
        var checks = 0
        XCTAssertThrowsError(try NativeFileAudioExport.encode(rawPCM: raw, frames: 144001, pcmSHA256: hash,
            to: out, codec: .aac64, check: {
                checks += 1
                if checks == 3 { try unrelated.write(to: out, options: .withoutOverwriting) }
            })) { XCTAssertEqual($0 as? NativeFileAudioExport.Failure, .destinationExists) }
        XCTAssertEqual(try Data(contentsOf: out), unrelated)
        XCTAssertEqual(try children(dir), ["out.m4a", "source.f32"])
    }
    func testLateCancellationDoesNotDeleteAlreadyPublishedCompleteFile() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), hash = try pcm(raw, count: 144001)
        let out = dir.appendingPathComponent("out.m4a")
        XCTAssertThrowsError(try NativeFileAudioExport.encode(rawPCM: raw, frames: 144001, pcmSHA256: hash,
            to: out, codec: .aac64, check: {
                if FileManager.default.fileExists(atPath: out.path) { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(try children(dir), ["out.m4a", "source.f32"])
        // Missing receipt means caller must reconcile; cancellation never erases completed output.
        XCTAssertThrowsError(try NativeFileAudioExport.write(rawPCM: raw, frames: 144001,
            pcmSHA256: hash, to: out, codec: .aac64)) {
            XCTAssertEqual($0 as? NativeFileAudioExport.Failure, .destinationExists)
        }
    }
    func testCancellationAndSourceReplacementPreserveInputAndUnknownFiles() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("source.f32"), hash = try pcm(raw, count: 144001)
        let out = dir.appendingPathComponent("out.m4a")
        var checks = 0
        XCTAssertThrowsError(try NativeFileAudioExport.encode(rawPCM: raw, frames: 144001, pcmSHA256: hash,
            to: out, codec: .aac64, check: {
                checks += 1
                if checks == 4 {
                    let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                        .first { $0.lastPathComponent.hasPrefix(".librox-export-") })
                    try Data("preserve".utf8).write(to: stage.appendingPathComponent("unknown"))
                    throw CancellationError()
                }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        let stage = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".librox-export-") })
        XCTAssertEqual(try children(stage), ["unknown"])
        XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("unknown"), encoding: .utf8), "preserve")
        checks = 0
        XCTAssertThrowsError(try NativeFileAudioExport.encode(rawPCM: raw, frames: 144001, pcmSHA256: hash,
            to: out, codec: .aac64, check: {
                checks += 1
                if checks == 3 {
                    try FileManager.default.moveItem(at: raw, to: dir.appendingPathComponent("original.f32"))
                    try Data(repeating: 0, count: 144001 * 4).write(to: raw)
                }
            })) { XCTAssertEqual($0 as? NativeFileAudioExport.Failure, .sourceIdentity) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("original.f32").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
#endif
