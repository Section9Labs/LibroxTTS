#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import LibroxChapterWorker
import LibroxChatterbox
import ChatterboxMacAcousticAudit

/// Stable local API classification. Native codec/model/OS errors retain their
/// own types; the eventual service translates them without parsing messages.
public enum ChatterboxMacRendererError: Error, Sendable, Equatable, CustomNSError {
    case invalidSource, invalidPassage, sourceCoverage, storage, closed, busy, unavailable
    public static var errorDomain: String { "LibroxChatterboxMac.Renderer" }
    public var errorCode: Int {
        switch self {
        case .invalidSource: 0
        case .invalidPassage: 1
        case .sourceCoverage: 2
        case .storage: 3
        case .closed: 4
        case .busy: 5
        case .unavailable: 6
        }
    }
}

/// One writer, one generation, one exact source. Never accumulates chapter PCM.
/// The supplied directory is a newly created private worker-owned job directory.
actor ChapterPCMSpool {
    struct Result: Sendable {
        let file: URL
        let frames: Int64
        let pcmSHA256: String
        let units: [ChapterAudioUnit]
    }
    private let file: URL
    private let handle: FileHandle
    private let identity: stat
    private let source: String
    private let original: NSString
    private let boundaries: Set<String.Index>
    private var digest = SHA256()
    private var frames: Int64 = 0
    private var units: [ChapterAudioUnit] = []
    private var generation: UUID?
    private var textEnd = 0
    private var closed = false
    private var failed = false
    private var completed = false

    init(source: String, directory: URL) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.utf16.count <= 131072, source.utf8.count <= 393216,
              directory.isFileURL, !directory.path.utf8.contains(0) else { throw ChatterboxMacRendererError.invalidSource }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ChatterboxMacRendererError.storage }
        let file = directory.appendingPathComponent("chapter.f32")
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ChatterboxMacRendererError.storage }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw ChatterboxMacRendererError.storage
        }
        self.file = file; self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.identity = info; self.source = source; self.original = source as NSString
        self.boundaries = Set(source.indices).union([source.endIndex])
    }
    deinit {
        try? handle.close()
        // Failed scratch PCM is ours only when the final leaf still matches.
        // Completed PCM is retained for the renderer's verified export/recovery.
        if !completed {
            var path = stat()
            if lstat(file.path, &path) == 0, path.st_dev == identity.st_dev, path.st_ino == identity.st_ino {
                unlink(file.path)
            }
        }
    }
    func append(_ passage: ChatterboxPreparedPassage) throws {
        guard let context = passage.unit.request.sourceContext,
              Data(passage.unit.request.text.utf8) == Data(context.originalText.utf8) else {
            failed = true
            throw ChatterboxMacRendererError.invalidPassage
        }
        try append(index: passage.index, generation: passage.generationID, range: context.range,
                   text: context.originalText, fragments: passage.unit.sourceFragments, samples: passage.samples)
    }
    // Internal seam for exact source/frame/cancellation tests; not a public renderer.
    func append(index: Int, generation: UUID, range: NSRange, text: String,
                fragments: [NSRange], samples: [Float]) throws {
        guard !closed, !failed else { throw ChatterboxMacRendererError.closed }
        do {
            try Task.checkCancellation()
            guard index == units.count, index < 4096, self.generation == nil || self.generation == generation,
                  valid(range), range.location >= textEnd, Data(original.substring(with: range).utf8) == Data(text.utf8),
                  ignored(NSRange(location: textEnd, length: range.location - textEnd)),
                  !fragments.isEmpty, fragments.count <= 128,
                  !samples.isEmpty, samples.count <= 121 * 24000,
                  Int64(samples.count) <= NativeFileAudioExport.maximumFrames - frames else { throw ChatterboxMacRendererError.invalidPassage }
            var end = range.location
            for fragment in fragments {
                guard valid(fragment), fragment.location >= end,
                      fragment.location >= range.location, NSMaxRange(fragment) <= NSMaxRange(range),
                      ignored(NSRange(location: end, length: fragment.location - end)) else { throw ChatterboxMacRendererError.sourceCoverage }
                end = NSMaxRange(fragment)
            }
            guard ignored(NSRange(location: end, length: NSMaxRange(range) - end)), samples.allSatisfy({ $0.isFinite && abs($0) <= 1 })
            else { throw ChatterboxMacRendererError.invalidPassage }
            try verify()
            for start in stride(from: 0, to: samples.count, by: 65536) {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let end = min(samples.count, start + 65536)
                    let bits = samples[start..<end].map { $0.bitPattern.littleEndian }
                    let data = bits.withUnsafeBufferPointer { Data(buffer: $0) }
                    try handle.write(contentsOf: data); digest.update(data: data)
                }
            }
            self.generation = generation
            units.append(ChapterAudioUnit(source: .init(offset: range.location, length: range.length),
                fragments: fragments.map { .init(offset: $0.location, length: $0.length) },
                startFrame: frames, frameCount: Int64(samples.count)))
            frames += Int64(samples.count); textEnd = NSMaxRange(range)
            try verify()
        } catch { failed = true; throw error }
    }
    func finish() throws -> Result {
        guard !closed, !failed else { throw ChatterboxMacRendererError.closed }
        closed = true
        try Task.checkCancellation()
        guard !units.isEmpty, ignored(NSRange(location: textEnd, length: original.length - textEnd)) else {
            throw ChatterboxMacRendererError.sourceCoverage
        }
        try verify()
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_size == frames * 4 else { throw ChatterboxMacRendererError.storage }
        try handle.synchronize()
        guard fchmod(handle.fileDescriptor, 0o400) == 0 else { throw ChatterboxMacRendererError.storage }
        try handle.close()
        try Task.checkCancellation()
        completed = true
        return Result(file: file, frames: frames,
            pcmSHA256: digest.finalize().map { String(format: "%02x", $0) }.joined(), units: units)
    }
    private func verify() throws {
        var descriptor = stat(), path = stat()
        guard fstat(handle.fileDescriptor, &descriptor) == 0, lstat(file.path, &path) == 0,
              descriptor.st_dev == identity.st_dev, descriptor.st_ino == identity.st_ino,
              path.st_dev == identity.st_dev, path.st_ino == identity.st_ino,
              descriptor.st_mode & S_IFMT == S_IFREG else { throw ChatterboxMacRendererError.storage }
    }
    private func valid(_ range: NSRange) -> Bool {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= original.length, range.length <= original.length - range.location,
              let span = Range(range, in: source) else { return false }
        return boundaries.contains(span.lowerBound) && boundaries.contains(span.upperBound)
    }
    private func ignored(_ range: NSRange) -> Bool {
        // Attachment placeholders preserve source positions but have no spoken text.
        original.substring(with: range).allSatisfy { $0.isWhitespace || $0 == "\u{FFFC}" }
    }
}
#endif
