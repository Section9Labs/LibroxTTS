# Mac chapter rendering: acceleration candidates

Research date: 29 October 2026 (America/Los_Angeles). Metadata/source inspection only; no candidate model download or inference is claimed here. The verified local machine is M3 Ultra / 256 GiB. Mac mini and iPhone results remain separate.

## Decision

Prioritize a Mac companion worker, with its own menu-bar status, controlled from Librox. Preserve the Catalyst reader. Shared SDK owns requests, chapter planning, rendering, verification, scheduling and audio/source maps; app integration owns documents, account/network/lifecycle adapters, settings and playback. Production companion and rendering code must be Swift-native (MLX Swift, Metal, Core ML); Python is offline qualification tooling only. Stock voices first; private phone recordings/conditioning are not uploaded. Remote generation is not yet implemented or approved for distribution.

Measure complete watermarked audio, not decoder token rate. Quality reference remains Standard. Target RTF <= 0.20; real time minimum and time to first ready chapter must be reported separately. The existing conservative CPU-acoustic sentence controls are not the best proven Mac configuration. Previously grouped/overlapped short Q8 V1 controls achieved RTF ~0.64–0.67 but failed their phone accuracy gate. Neither establishes current V3 sustained throughput.

## Candidate order

1. **Full-precision multilingual V3 through MLX-Audio.** `mlx-community/chatterbox-multilingual-v3`, revision `03565773edd72e949572557597af8063bb49a18a`, is converted from ResembleAI/chatterbox; model metadata describes 677.7M full-stack floating parameters / ~2.71 GB F32. Source `Blaizzy/mlx-audio` revision `b80c4edb4181c102f72b56bbf6ce9438a2050354` implements T3, S3Gen CFM and HiFT in MLX. The inspected CFM batches conditional/unconditional inputs into one estimator call and uses cosine-scheduled Euler updates. This addresses the CPU acoustic bottleneck directly. Model requires separate S3TokenizerV2. Source snapshot and hashes are in `/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-acceleration-research-v01/manifest.json`. These files were not installed into shipping code.

   This is a runtime conversion, not demonstrated better speech than Standard. Preserve the exact V3 tokenizer/normalization/conditioning/CFG and all ten CFM steps for the initial control. Inspected model/generation source contains no Perth stage: integrate and time the selected explicit watermark policy before any listening-ready export or full-pipeline speed claim. Watermark bypass is now authorized as a separately labelled experiment; do not call its output watermarked or compare it silently with old mandatory-Perth runs. A Python prototype is useful for qualification, but does not establish a distributable Swift companion or iPhone backend. Do not install a moving dependency branch into the app.

2. **Metal/ggml multilingual F16 control.** `gianni-cor/chatterbox.cpp` supports multilingual, full CFG, ten CFM steps and F16 weights. Authors report M3 Ultra short warm Spanish RTF ~0.37–0.38, excluding load. Treat this as external evidence, not reproduced performance, a V3 checkpoint identity guarantee, whole-chapter quality or watermarked throughput. Freeze actual source/checkpoint/tokenizer and audit watermark before execution. Do not copy their seven-step quality shortcut into our baseline: their log-mel cosine is not Matt's listening approval. Native C++ is packageable behind a library adapter if qualified. Benchmark this only after the first MLX candidate, not simultaneously duplicating jobs/models.

3. **New Core ML exact-shape acoustic artifact.** Existing exact700 specialization preserves weights and ordered graph operations, including a separately reviewed precision audit. CPU trajectory parity, isolated GPU, combined-context GPU and complete watermarked PCM qualification are still pending. Original failed GPU/ANE paths remain stopped. Do not change input padding or precision to obtain a passing receipt.

## Checkpoints which are not interchangeable

- `mlx-community/chatterbox-fp16` is multilingual V2, not V3.
- `groxaxo/chatterbox-multilingual-v3-bf16` is a precision conversion, not a finetune; published RTX3060 results do not establish Apple performance. Full F32 MLX V3 is the first quality control.
- Official `ResembleAI/Chatterbox-Multilingual-es-es` (and regional packs) is a full-size V3 language finetune, not Turbo or distillation. Its own T3/tokenizer/acoustic assets must remain matched. It is an optional Spanish quality comparison after the runtime baseline.
- Official Chatterbox Flash releases an English-tokenizer block-diffusion decoder. Its MLX backend accelerates the LLaMA backbone while the PyTorch side remains CPU. It is not a drop-in multilingual full-GPU solution.
- FluidAudio's Core ML multilingual backend is explicitly beta, has short static limits, currently built-in voice only, and documents no watermark stage. Nano's published 5.4–6x is English-only and not the multilingual model.
- Direct native Swift source inspection now found regular multilingual Chatterbox and shared S3Gen flow/vocoder in MLX-Audio Swift at `d08558975ef219e5ed38c71fe2522cc03167899f`. Its model README documents Regular (LLaMA520M,23languages) and Turbo. This is a reusable native candidate, not proof of V3 tokenizer/weight/arithmetic compatibility. Source-only snapshot: owned `chatterbox-macos-acceleration-research-v01/swift-source-d0855897`. No dependency was added or native model built. Prioritize qualifying a native acoustic seam with the already validated Librox decoder; do not silently replace the decoder or import a moving package branch. Retain license/provenance if code is reused.

## Optimization sequence

- Keep one qualified model and stock conditioning resident; separate cold load/conditioning from warm generation while reporting both in chapter latency.
- Keep acoustic tensors and intermediate states on GPU where supported; avoid `.item()`, `asArray`, NumPy/CPU conversions and synchronization inside hot loops. Synchronize the final waveform before stopping the timer. Include cadence, host copy, Perth, codec encode and verified asset commit.
- Preserve CFG and solver settings first. Batch independent conditional/unconditional calls when mathematically/layout compatible. Frozen-input parity precedes listening and speed decisions.
- Evaluate compiled stable-shape kernels once, retain compiled functions, and measure cold compilation separately. MLX documents shape/dtype changes and recreated functions as recompilation triggers. Fusion may alter numerics: keep existing oracle criteria and create no passing-reference shortcut.
- Start with one decoder and one acoustic worker overlapped. Compare this to two complete chapter workers with isolated caches/RNG/conditioning and bounded process memory. Do not assume more streams or workers increase GPU throughput. Report first-chapter latency, aggregate audio seconds/sec, RSS/MLX peak, thermal state and sustained results. Default concurrency stays one until the measured configuration is reviewed.
- For Core ML, inspect actual operation placement with MLComputePlan/Xcode performance reports. `.all` or `.cpuAndNeuralEngine` permits devices; it does not prove ANE execution. Prefer ANE only where validated placement and end-to-end timing win; the Mac GPU may be the workhorse for dynamic full-stack MLX.
- No private ANE API, entitlement changes, reduced CFM steps, silent CPU fallback or relaxed precision guard as a speed claim. Matt subsequently authorized a separately identified watermark opt-out if measurably useful; old watermarked runs remain immutable. Current per-unit watermark work is about 1.5% of overlapped wall time; that is accounting, not a measured bypass speedup. Include the actual policy in every report and cache/recipe identity.

## Bounded next experiment

Use pinned full-precision MLX V3 with public stock/synthetic reference only and frozen English/Spanish text. Audit loader, complete weight hashes and separate tokenizer before initialization. Dedicated dependency environment, bounded memory/thermal/deadline watchdog, no downloads inside timed generation. Start with one complete output per language, then the same backend at two workers only after correct output. Compare against Standard with matched conditioning where possible; otherwise label conditioning differences explicitly. Publish generated-only audio after Perth and output validation. Record all failures. No 5x, battery or phone claim from upstream benchmarks.

## Primary sources

- https://huggingface.co/mlx-community/chatterbox-multilingual-v3
- https://github.com/Blaizzy/mlx-audio/blob/b80c4edb4181c102f72b56bbf6ce9438a2050354/mlx_audio/tts/models/chatterbox/chatterbox.py
- https://github.com/Blaizzy/mlx-audio/blob/b80c4edb4181c102f72b56bbf6ce9438a2050354/mlx_audio/tts/models/chatterbox/s3gen/flow_matching.py
- https://github.com/gianni-cor/chatterbox.cpp
- https://huggingface.co/ResembleAI/Chatterbox-Multilingual-es-es
- https://huggingface.co/groxaxo/chatterbox-multilingual-v3-bf16
- https://github.com/resemble-ai/chatterbox-flash/tree/master
- https://github.com/FluidInference/FluidAudio/blob/main/Documentation/TTS/Chatterbox.md
- https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode
- https://developer.apple.com/videos/play/wwdc2023/10049/
- https://ml-explore.github.io/mlx/build/html/usage/compile.html
- https://ml-explore.github.io/mlx/build/html/usage/using_streams.html
- https://apple.github.io/coremltools/docs-guides/source/opt-overview.html

## Latest watermark result

Native Swift explicit opt-out is implemented in SDK10a00d8; five focused Release tests passed. Default identity and the two default audio PCM streams are byte-identical to the prior control. A new paired short Standard EN/ES control completed with explicit disabled policy and a deliberately absent Perth directory: no hidden load/fallback, zero watermark work. Wall seconds marked→unmarked: EN9.358→9.255;ES10.183→10.389. This single pair does not show a reliable end-to-end speed win, and cadence can change slightly when the waveform changes. Keep the option and report it accurately; prioritize the acoustic GPU path. The final phone build remains pinned to the previously reviewed watermarked SDK e718bfe.
