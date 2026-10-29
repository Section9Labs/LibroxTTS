#if os(macOS)
import Foundation
import CryptoKit
import MLX
import ChatterboxCoreML

/// Freezes public frontend vectors before either decoder evaluator is run.
/// This does not instantiate a T3 backbone, synthesize audio, or create an app oracle.
enum ReferenceHoldoutPreparation {
    static let planSHA256 = "539d1f2a270cb24af5f607c8b3b1f486a3486b87570c7a93ec29840dba961311"
    static let parentSHA256 = "63a398b2c4d199f080da34844429a1c5df10407c552af528cf670b98e40ade0e"
    static let chunkSHA256 = "539f8d59f5e1b93c8b15fc3f918a9c3e25268e7b782f31c6189c2a5fefc25cff"
    static let continuationIDs = [173, 920, 31, 404, 2100, 781, 64, 1500]
    static let identitiesSHA256 = "7b2c51f54a8d5bc8c5fd973cac7a7babe242f7feddaf74541cbda75a25fe1b14"
    static let absentFrontendFiles = ["config.json", "chat_template.jinja", "chat_template.json"]
    static let frontendFiles = ["default-conds.safetensors", "tokenizer.json", "tokenizer_config.json",
        "speech_emb.npy", "speech_pos_emb.npy", "text_emb.npy", "text_pos_emb.npy",
        "spkr_enc_weight.npy", "spkr_enc_bias.npy", "emotion_adv_fc_weight.npy", "perceiver_query.npy",
        "perceiver_norm_weight.npy", "perceiver_norm_bias.npy", "perceiver_to_q_weight.npy",
        "perceiver_to_q_bias.npy", "perceiver_to_k_weight.npy", "perceiver_to_k_bias.npy",
        "perceiver_to_v_weight.npy", "perceiver_to_v_bias.npy", "perceiver_proj_out_weight.npy",
        "perceiver_proj_out_bias.npy"]
    enum Failure: Error { case identity, plan, selection, shape }
    struct Plan: Decodable {
        struct Case: Decodable { let id: String, language: String, text: String }
        let exaggeration: Float, guidance: Float
        let continuation_ids: [Int], speech_position_indices: [Int]
        let cases: [Case]
    }
    struct Files {
        let model: URL, plan: URL, parent: URL, chunk: URL, frontendIdentities: URL, output: URL
    }
    struct Selection: Equatable {
        let text: String, wordCount: Int, ids: [Int32]
        var rows: Int { 36 + ids.count }
    }

    /// Token counts alone choose whole-word prefixes; decoder logits are unavailable here.
    /// Enumerate all authored prefixes, since a tokenizer's counts need not be monotonic.
    static func select(text: String, kind: String, encode: (String) throws -> [Int32],
                       check: () throws -> Void) throws -> Selection {
        func admitted(_ candidate: String, wordCount: Int) throws -> Selection? {
            try check()
            guard !candidate.isEmpty, candidate.utf8.count <= 8_000 else { return nil }
            let ids = try encode(candidate)
            guard !ids.isEmpty, ids.allSatisfy({ (0..<2454).contains(Int($0)) }),
                ids.first == MTLTextTokenizer.startTextToken, ids.last == MTLTextTokenizer.stopTextToken,
                ids.count <= 512 - 36, 36 + ids.count + 8 <= 1536 else { return nil }
            return Selection(text: candidate, wordCount: wordCount, ids: ids)
        }
        if kind == "short" {
            guard let exact = try admitted(text, wordCount: text.split(whereSeparator: \.isWhitespace).count),
                exact.rows <= 128 else { throw Failure.selection }
            return exact
        }
        guard kind == "boundary" || kind == "long" else { throw Failure.plan }
        var selected: Selection?, words = 0
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if !text[index].isWhitespace && (next == text.endIndex || text[next].isWhitespace) {
                words += 1
                if let candidate = try admitted(String(text[..<next]), wordCount: words) {
                    if kind == "boundary", (250...255).contains(candidate.rows) { selected = candidate }
                    if kind == "long", (500...512).contains(candidate.rows) { return candidate }
                }
            }
            index = next
        }
        guard let selected else { throw Failure.selection }
        return selected
    }

    static func run(_ f: Files) async throws {
        let budget = CertifiedHalfProjection.Budget()
        try budget.check()
        guard !FileManager.default.fileExists(atPath: f.output.path),
            try ChatterboxMLXRenderer.digest(f.plan) == planSHA256,
            try ChatterboxMLXRenderer.digest(f.parent) == parentSHA256,
            try ChatterboxMLXRenderer.digest(f.chunk) == chunkSHA256 else { throw Failure.identity }
        let identitySize = try f.frontendIdentities.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let identitySize, (1...8192).contains(identitySize) else { throw Failure.identity }
        let identityHandle = try FileHandle(forReadingFrom: f.frontendIdentities)
        defer { try? identityHandle.close() }
        guard let identitiesData = try identityHandle.read(upToCount: 8193),
            try identityHandle.read(upToCount: 1)?.isEmpty != false else { throw Failure.identity }
        guard identitiesData.count == identitySize,
            SHA256.hash(data: identitiesData).map({ String(format: "%02x", $0) }).joined() == identitiesSHA256
        else { throw Failure.identity }
        let identities = try JSONDecoder().decode([String: String].self, from: identitiesData)
        guard Set(identities.keys) == Set(frontendFiles), identities.values.allSatisfy({
            $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        }) else { throw Failure.identity }
        func verifyFrontend() throws {
            guard absentFrontendFiles.allSatisfy({ !FileManager.default.fileExists(atPath: f.model.appendingPathComponent($0).path) })
            else { throw Failure.identity }
            for name in frontendFiles {
                try budget.check()
                guard try ChatterboxMLXRenderer.digest(f.model.appendingPathComponent(name)) == identities[name]
                else { throw Failure.identity }
            }
        }
        try verifyFrontend()
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: f.plan))
        let caseIDs = ["en-short", "en-boundary", "en-long", "es-short", "es-boundary", "es-long"]
        guard plan.cases.map(\.id) == caseIDs, plan.exaggeration == 0.5, plan.guidance == 0.5,
            plan.continuation_ids == continuationIDs, plan.speech_position_indices == Array(1...8),
            plan.cases.allSatisfy({ $0.id.hasPrefix($0.language + "-") && ["en", "es"].contains($0.language) })
        else { throw Failure.plan }
        try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: false)
        var report: [String: Any] = ["completed": false, "input_freeze_only": true,
            "decoder_forward_count": 0, "production_clearance": false, "plan_sha256": planSHA256,
            "parent_sha256": parentSHA256, "chunk_controls_sha256": chunkSHA256,
            "frontend_files": identities, "frontend_required_absences": absentFrontendFiles,
            "frontend_identity_manifest_sha256": identitiesSHA256]
        do {
            let tokenizer = try await MTLTextTokenizer(modelFolder: f.model)
            try budget.check()
            var selections: [Selection] = []
            for item in plan.cases {
                guard let suffix = item.id.split(separator: "-").last else { throw Failure.plan }
                let kind = String(suffix)
                selections.append(try select(text: item.text, kind: kind,
                    encode: { tokenizer.encode($0, language: item.language) }, check: budget.check))
            }
            let builder = try await ChatterboxMultilingualPromptBuilder(modelDirectory: f.model)
            try budget.check()
            var arrays: [String: MLXArray] = [:], cases: [[String: Any]] = []
            for (item, selected) in zip(plan.cases, selections) {
                try budget.check()
                let prompt = try builder.prepare(text: selected.text, language: item.language,
                    conditioningFile: f.model.appendingPathComponent("default-conds.safetensors"),
                    exaggeration: plan.exaggeration, guidance: plan.guidance, maxTokens: 8)
                guard prompt.length == selected.rows, prompt.textTokens == selected.ids,
                    prompt.embeddings.count == 2 * selected.rows * 1024,
                    prompt.embeddings.allSatisfy(\.isFinite) else { throw Failure.shape }
                var speech: [Float] = []
                for (token, position) in zip(continuationIDs, plan.speech_position_indices) {
                    try budget.check()
                    let row = try builder.speechInput(token: token, position: position)
                    guard row.count == 1024, row.allSatisfy(\.isFinite) else { throw Failure.shape }
                    speech += row + row
                }
                Device.withDefaultDevice(.cpu) {
                    arrays[item.id + ".prefix"] = MLXArray(prompt.embeddings, [2, prompt.length, 1024])
                    arrays[item.id + ".continuations"] = MLXArray(speech, [8, 2, 1, 1024])
                    arrays[item.id + ".text_ids"] = MLXArray(prompt.textTokens)
                    eval(arrays[item.id + ".prefix"]!, arrays[item.id + ".continuations"]!, arrays[item.id + ".text_ids"]!)
                }
                cases.append(["id": item.id, "language": item.language, "selected_text": selected.text,
                    "selected_word_count": selected.wordCount, "text_tokens": selected.ids.map(Int.init),
                    "prefix_length": prompt.length, "prefix_positions": Array(0..<prompt.length),
                    "incoming_decode_offsets": Array(prompt.length..<(prompt.length + 8)),
                    "continuation_ids": continuationIDs, "speech_position_indices": Array(1...8),
                    "maximum_evaluated_position": prompt.length + 7,
                    "fixed_chunk_rows": 64, "exaggeration": plan.exaggeration, "guidance": plan.guidance])
            }
            try verifyFrontend(); try budget.check()
            let vectors = f.output.appendingPathComponent("public-input-vectors.safetensors")
            try Device.withDefaultDevice(.cpu) {
                try save(arrays: arrays, metadata: ["scope": "Frozen public input vectors; no decoder evaluated"], url: vectors)
            }
            report["cases"] = cases; report["vectors_sha256"] = try ChatterboxMLXRenderer.digest(vectors)
            report["tensor_count"] = arrays.count; report["continuation_ids"] = continuationIDs
            try budget.check()
            report["completed"] = true
            try write(report, to: f.output.appendingPathComponent("report.json"))
        } catch {
            report["completed"] = false; report["error"] = String(describing: error)
            try? write(report, to: f.output.appendingPathComponent("report.json")); throw error
        }
    }
    private static func write(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: file, options: .atomic)
    }
}
#endif
