import Foundation

// Pinned upstream regular-model name mapping, with no numerical conversion.
// See PROVENANCE.md. Only the exact checkpoint/header is accepted by the probe.
enum AcousticKeyMapping {
    static func remapRegularS3GenKey(_ key: String) -> String {
        var k = key

        // --- 1. Block array naming: setattr → Swift [Module] arrays ---
        // Python uses `down_blocks_0`, Swift uses `down_blocks.0`
        // Must handle multi-digit indices: down_blocks_12 → down_blocks.12
        k = k.replacingOccurrences(
            of: #"down_blocks_(\d+)\."#,
            with: "down_blocks.$1.",
            options: .regularExpression)
        k = k.replacingOccurrences(
            of: #"mid_blocks_(\d+)\."#,
            with: "mid_blocks.$1.",
            options: .regularExpression)
        k = k.replacingOccurrences(
            of: #"up_blocks_(\d+)\."#,
            with: "up_blocks.$1.",
            options: .regularExpression)

        // --- 2. Transformer array naming within blocks ---
        // Python: `transformer_0.` → Swift: `transformer_blocks.0.`
        k = k.replacingOccurrences(
            of: #"\.transformer_(\d+)\."#,
            with: ".transformer_blocks.$1.",
            options: .regularExpression)
        // Also handle top-level transformer_ (without leading dot)
        if k.hasPrefix("transformer_") {
            k = k.replacingOccurrences(
                of: #"^transformer_(\d+)\."#,
                with: "transformer_blocks.$1.",
                options: .regularExpression)
        }

        // --- 3. Attention naming: Python sanitized → Swift original PyTorch names ---
        // Python: .attn.query_proj. → Swift: .attn1.to_q.
        k = k.replacingOccurrences(of: ".attn.query_proj.", with: ".attn1.to_q.")
        k = k.replacingOccurrences(of: ".attn.key_proj.", with: ".attn1.to_k.")
        k = k.replacingOccurrences(of: ".attn.value_proj.", with: ".attn1.to_v.")
        k = k.replacingOccurrences(of: ".attn.out_proj.", with: ".attn1.to_out.0.")

        // --- 4. FeedForward naming: Python LayerList → Swift named submodules ---
        // Python: .ff.layers.0. (GELU proj) → Swift: .ff.gelu_gate.proj.
        // Python: .ff.layers.1. (output Linear) → Swift: .ff.out_proj.
        k = k.replacingOccurrences(of: ".ff.layers.0.", with: ".ff.gelu_gate.proj.")
        k = k.replacingOccurrences(of: ".ff.layers.1.", with: ".ff.out_proj.")

        // --- 5. CausalBlock1D: Python named attrs → Swift block array ---
        // Python CausalBlock1D stores: self.conv (CausalConv1d), self.norm (LayerNorm)
        // Swift S3GenCausalBlock1D stores: block[0] (CausalConv1d), block[1] (LayerNorm)
        //
        // Python key: .block1.conv.conv.weight → Swift: .block1.block.0.conv.conv.weight
        // Python key: .block1.norm.weight → Swift: .block1.block.1.weight
        // Same for block2 and final_block
        //
        // IMPORTANT: Must replace `conv.conv.` (CausalConv1d path) with `block.0.conv.conv.`
        // and `norm.` with `block.1.` — NOT just `conv.` → `block.0.` which would eat one
        // level of the CausalConv1d nesting.
        k = k.replacingOccurrences(of: ".block1.conv.conv.", with: ".block1.block.0.conv.conv.")
        k = k.replacingOccurrences(of: ".block1.norm.", with: ".block1.block.1.")
        k = k.replacingOccurrences(of: ".block2.conv.conv.", with: ".block2.block.0.conv.conv.")
        k = k.replacingOccurrences(of: ".block2.norm.", with: ".block2.block.1.")
        k = k.replacingOccurrences(of: ".final_block.conv.conv.", with: ".final_block.block.0.conv.conv.")
        k = k.replacingOccurrences(of: ".final_block.norm.", with: ".final_block.block.1.")

        // --- 6. res_conv: bare Conv1d → S3GenConv1dPT wrapper ---
        // Python: .res_conv.weight → Swift: .res_conv.conv.weight
        // Must NOT double-convert if already has .conv.
        // The Python key is `res_conv.weight` or `res_conv.bias` (bare nn.Conv1d).
        // Swift has S3GenConv1dPT which nests as res_conv.conv.weight.
        k = k.replacingOccurrences(
            of: #"\.res_conv\.(weight|bias)"#,
            with: ".res_conv.conv.$1",
            options: .regularExpression)

        // --- 7. final_proj: bare Conv1d → S3GenConv1dPT wrapper ---
        // Python: final_proj.weight → Swift: final_proj.conv.weight
        k = k.replacingOccurrences(
            of: #"\.final_proj\.(weight|bias)"#,
            with: ".final_proj.conv.$1",
            options: .regularExpression)
        // Also handle if final_proj is at the start of the key
        if k.hasPrefix("final_proj.") && !k.hasPrefix("final_proj.conv.") {
            k = k.replacingOccurrences(
                of: #"^final_proj\.(weight|bias)"#,
                with: "final_proj.conv.$1",
                options: .regularExpression)
        }

        // --- 8. Downsample/Upsample: bare Conv1d → S3GenConv1dPT/S3GenConvTranspose1dPT ---
        // Python Downsample1D: .downsample.conv.weight (nn.Conv1d is self.conv)
        // Swift S3GenDownsample1D: .downsample.conv.conv.weight (S3GenConv1dPT wraps Conv1d)
        // But: the last-layer downsample is a CausalConv1d which already has .conv.conv
        // So only add extra .conv when not already present.
        //
        // Match `.downsample.conv.weight` but NOT `.downsample.conv.conv.weight`
        k = k.replacingOccurrences(
            of: #"\.downsample\.conv\.(weight|bias)$"#,
            with: ".downsample.conv.conv.$1",
            options: .regularExpression)
        k = k.replacingOccurrences(
            of: #"\.upsample\.conv\.(weight|bias)$"#,
            with: ".upsample.conv.conv.$1",
            options: .regularExpression)

        // --- 9. MLP naming: Python sanitized mlp_linear → Swift mlp.0 ---
        // Python sanitize: .mlp.1. → .mlp_linear.
        // So safetensors has: .mlp_linear.weight
        // Swift has: @ModuleInfo(key: "mlp") var mlp: [Linear] → .mlp.0.weight
        k = k.replacingOccurrences(of: ".mlp_linear.", with: ".mlp.0.")

        // --- 10. mel2wav (HiFi-GAN vocoder): bare Conv1d → HiFiConv1d/HiFiConvTranspose1d ---
        //
        // The Regular model's Python HiFi-GAN uses bare nn.Conv1d/nn.ConvTranspose1d everywhere,
        // so safetensors keys have no `.conv` wrapping level:
        //   mel2wav.conv_pre.weight, mel2wav.resblocks.0.convs1.0.weight, etc.
        //
        // Swift's HiFiConv1d/HiFiConvTranspose1d wrap Conv1d with @ModuleInfo(key: "conv"),
        // adding a `.conv` level in the key path:
        //   mel2wav.conv_pre.conv.weight, mel2wav.resblocks.0.convs1.0.conv.weight, etc.
        //
        // Insert `.conv` before terminal `.weight`/`.bias` for all mel2wav Conv1d parameters.
        // Skip non-Conv1d parameters (Snake .alpha, Linear .weight/.bias in classifier/l_linear).
        if k.hasPrefix("mel2wav.") {
            k = Self.remapRegularMel2WavKey(k)
        }

        return k
    }

    static func remapRegularMel2WavKey(_ key: String) -> String {
        // Strip mel2wav. prefix, process, then re-add
        guard key.hasPrefix("mel2wav.") else { return key }
        let subKey = String(key.dropFirst("mel2wav.".count))

        // Match all Conv1d/ConvTranspose1d terminal patterns:
        //   conv_pre.{weight,bias}
        //   conv_post.{weight,bias}
        //   ups.N.{weight,bias}
        //   source_downs.N.{weight,bias}
        //   resblocks.N.convs1.M.{weight,bias}
        //   resblocks.N.convs2.M.{weight,bias}
        //   source_resblocks.N.convs1.M.{weight,bias}
        //   source_resblocks.N.convs2.M.{weight,bias}
        //   f0_predictor.condnet.N.{weight,bias}
        //
        // Pattern: these all end with either:
        //   (named_module).{weight,bias}  where named_module is conv_pre, conv_post
        //   (array_module).N.{weight,bias} where array_module is ups, source_downs, condnet, convs1, convs2
        //
        // We insert `.conv` before the terminal `.weight`/`.bias`.
        // Regex approach: match known Conv1d parent patterns and insert .conv

        // conv_pre / conv_post
        let remapped = subKey
            .replacingOccurrences(
                of: #"^(conv_pre|conv_post)\.(weight|bias)$"#,
                with: "$1.conv.$2",
                options: .regularExpression)
            // ups.N / source_downs.N
            .replacingOccurrences(
                of: #"^(ups|source_downs)\.(\d+)\.(weight|bias)$"#,
                with: "$1.$2.conv.$3",
                options: .regularExpression)
            // resblocks.N.convs{1,2}.M / source_resblocks.N.convs{1,2}.M
            .replacingOccurrences(
                of: #"^((?:source_)?resblocks\.\d+\.convs[12]\.\d+)\.(weight|bias)$"#,
                with: "$1.conv.$2",
                options: .regularExpression)
            // f0_predictor.condnet.N
            .replacingOccurrences(
                of: #"^(f0_predictor\.condnet\.\d+)\.(weight|bias)$"#,
                with: "$1.conv.$2",
                options: .regularExpression)

        return "mel2wav.\(remapped)"
    }
}
