#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import LibroxChatterboxMLX
import ChatterboxMacAcousticAudit

/// Exact full-quality frontend already bound by the qualified native EN/ES run.
/// This adds admission/recipe identity, not a new numerical reference or model.
enum StandardModelIdentity {
    static let frontend: [String: String] = [
        "emotion_adv_fc_weight.npy": "2aca1902f1e7a08d3424555d010e52aa162c05abc46cfb1eb136aabfeec39e7d",
        "perceiver_norm_bias.npy": "05d200b834e7c4484127fc607fc74e91544e9e61b02be7680ca48d2671c87c68",
        "perceiver_norm_weight.npy": "e23cb5b05e17be8e9aa26b0605cc3152be49b699e426d2247cafb22337cb52c2",
        "perceiver_proj_out_bias.npy": "15ce24b007e2061861e4051f046fcf16c1fcf6eb501e3bea4f0f092bc5a1d666",
        "perceiver_proj_out_weight.npy": "3f1f40b44a7ca36796296fba09245a4115dbb8b4e36418d8963938adb92d933a",
        "perceiver_query.npy": "8a726168e6ed1a635da954f67ad1f972be576ca1db547143bde418908417dec7",
        "perceiver_to_k_bias.npy": "88f074b8632be004c50072b68cbd9bfc3f0d03e9cae47af46aca8a25145e4ea4",
        "perceiver_to_k_weight.npy": "3adf46928cfd6eb29d92726ed1f3e6c1a88c47552badd9d3d87dbe1c855b4df7",
        "perceiver_to_q_bias.npy": "b950898d905d0e915b48075da0a7a5877a0eb40e477844cddccda4841f8f5a98",
        "perceiver_to_q_weight.npy": "f7d6ccbe4538bc17e03ca1fac949b27aec446b85ae81169ad4c704067ca40b60",
        "perceiver_to_v_bias.npy": "3a2c6076bb0696dfd6509c70de751a2ed9a2c0d785907400c39e5e9dcdf48131",
        "perceiver_to_v_weight.npy": "8fdddea86051a59c74de2c6ce5c64efe275dee1161c769b5110f3b8333bafad1",
        "speech_emb.npy": "a1125b140ecd908282b73fcf35facae672e67651d7bbab63aea82ef1e2dc7c7d",
        "speech_pos_emb.npy": "696e4359bb35c84dbafc7d6adcd43f9fb978951f9dd3afd30d9cea1fe0ff68f7",
        "spkr_enc_bias.npy": "45c8ba6669ca14d823d48d34542a460d58f532fb904e2bd9973c57a61f2aa785",
        "spkr_enc_weight.npy": "dfd58b66609e036657b5ef75b8a224d9147f54a089c339b2c44db4dad6e82fe3",
        "text_emb.npy": "a079f5b49a575aa194d64a937d0ee5b03e5cb30cb3611acfcd7b5555201a94a2",
        "text_pos_emb.npy": "cfdd899b359148c6349cc8274e560f117530a75e866f689c9ad32c416f4f2072",
        "tokenizer.json": "69632f47220a788a52ce2661d096453c5655e9bf25289d89a8d832c46ee07dbf",
        "tokenizer_config.json": "6d046b0c46e5225efeae0f7383ce7eeef74025f7c7a55a3d07c3cc49b218ba16",
    ]
    static let absentFrontend = ["added_tokens.json", "chat_template.jinja", "chat_template.json", "config.json", "merges.txt", "special_tokens_map.json", "vocab.json"]
    static func modelSHA256() throws -> String {
        struct Pack: Encodable {
            let revision, decoder, oracle, acoustic: String
            let frontend: [String: String]
            let absent: [String]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(Pack(revision: "mac-standard-model-pack-1",
            decoder: ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate.weightsSHA256,
            oracle: ChatterboxMLXRenderer.DecoderProfile.mixedFloat16Accurate.oracleSHA256,
            acoustic: AcousticInventory.checkpointSHA256, frontend: frontend, absent: absentFrontend))
        return ChatterboxMacChapterRequest.hash(bytes)
    }
    static func verifyFrontend(_ directory: URL) throws {
        guard directory.isFileURL, !directory.path.utf8.contains(0) else { throw ChatterboxMacRendererError.invalidSource }
        for name in absentFrontend {
            var info = stat()
            guard lstat(directory.appendingPathComponent(name).path, &info) != 0, errno == ENOENT else {
                throw ChatterboxMacRendererError.invalidSource
            }
        }
        for (name, expected) in frontend.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(name)
            let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw ChatterboxMacRendererError.invalidSource }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_size > 0, before.st_size <= 128 * 1024 * 1024 else { throw ChatterboxMacRendererError.invalidSource }
            var hash = SHA256(), count: Int64 = 0
            while true {
                let done = try autoreleasepool {
                    try Task.checkCancellation()
                    let p = ProcessInfo.processInfo
                    guard !p.isLowPowerModeEnabled, p.thermalState != .serious, p.thermalState != .critical else {
                        throw ChatterboxMacRendererError.unavailable
                    }
                    let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                    guard Int64(data.count) <= before.st_size - count else { throw ChatterboxMacRendererError.invalidSource }
                    count += Int64(data.count); hash.update(data: data)
                    return data.isEmpty
                }
                if done { break }
            }
            var after = stat(), path = stat()
            guard count == before.st_size, ChatterboxMacChapterRequest.hashDigest(hash.finalize()) == expected,
                  fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
                  same(before, after), same(before, path) else { throw ChatterboxMacRendererError.invalidSource }
        }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }
}
#endif
