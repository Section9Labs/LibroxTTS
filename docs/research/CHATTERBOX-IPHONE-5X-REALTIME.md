# Five-times-playback Chatterbox on iPhone

Research date:2026-10-28 (America/Los_Angeles). Library owner:this Codex chat.
App integration:T3. Status:research and measured budget analysis, not an achieved
iPhone speedup, a new phone build, or battery/quality acceptance.

## Question and decision

How can the complete multilingual narration pipeline generate five seconds of
finished audio per second of computation on iPhone17ProMax, preserve voice and
expression quality, and avoid sustained heat/battery drain?

The objective is **5× actual playback**, not5× faster decoder kernels. At normal
playback this is RTF≤0.20;10seconds of audio must finish in≤2seconds. At1.5×
playback, five-times-playback requires7.5seconds of nominal audio per wall second
(RTF≤0.1333). Cold loading, time to first audio and steady throughput are distinct.

## Our evidence, distinguished from published claims

| Owned test | Whole-pipeline result | Interpretation |
| --- | --- | --- |
| Current Mac mixed-FP16,4EN/ES clips | 21.80s audio /18.20s render | 1.20× real time |
| Local exact-V3 Q8, same4requests | 22.12s /17.64s | 1.25×; needs another3.99× throughput for target |
| Local exact-V3 Q4, same4requests | 21.92s /20.08s | 1.09×; no end-to-end win in this sample |
| One physical build294 passage | 6.92s /11.392s | Needs8.23× throughput to reach5× playback |

Mac receipts use identical stock conditioning, frontend prefixes, sampling
settings/seed42 and acoustic noise42. Generated token histories differ, so their
wall times are preliminary throughput observations, not isolated kernel comparisons.
These four short clips establish neither sustained iPhone performance nor energy.

Q8 reduced resident decoder parameters45.35%, not whole-app RAM45%. It passed3/18
existing strict FP32-reference checks; Q4 passed0/18. Baseline passed18/18. These
are model-internal differences, not human quality scores. Neither candidate has
production precision clearance. The original F32/mixed gates stay unchanged.

For that phone passage, T3 prefill+decode consumed5.574s and synthesis5.677s.
The full target budget is1.384s. Even a free decoder would require acoustics to
improve by at least4.10×. Even free acoustics would require decoder work to improve
by at least4.03×. Overlap cannot hide a stage that itself exceeds the target.
The older ANE-T3 timings in historical notes are not the current MLX baseline;
do not combine the best stages from unrelated trials as a measured pipeline.

Receipts:`/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01`;
phone evidence:current release handoff `codex-chatterbox-phone-latest.json`.
`Scripts/chatterbox_performance_budget.py` evaluates completed receipts without
loading models; its results are in the owned research evidence directory.

## Findings from primary sources

### 1. Match compression to the accelerator

Core ML distinguishes compressed storage from faster execution. Apple recommends
palettization for ANE memory/latency, identifies W8A8 opportunities on newer ANEs,
and highlights block-quantized INT4 for Mac GPU workloads. These are different
formats from our MLX affine Q8. Activation quantization can slow CPU/GPU fallback;
verify placement before assuming an INT8 model uses faster INT8 compute.
[Core ML optimization](https://apple.github.io/coremltools/docs-guides/source/opt-overview.html),
[quantization performance](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-perf.html).

Decision:retain Q8 as the leading footprint candidate; do not assume Q4 or an
ANE-labelled export is faster. Evaluate device-specific precision policies with
exact artifact identities, protected sensitive layers and independent references.

### 2. Core AI is a real new backend option, not a Core ML toggle

Apple's Core AI pipeline uses PyTorch export/conversion to `.aimodel`, specialization
and caches, asynchronous compute streams and dedicated debugging/profiling.
Its iOS optimization guidance emphasizes static tensors, channels-first layouts
and supported convolution/quantization patterns. Model authoring must preserve
semantics with module and whole-model comparisons.
[Core AI](https://developer.apple.com/documentation/coreai/),
[authoring and optimization](https://developer.apple.com/videos/play/wwdc2026/325/),
[Apple implementation guidance](https://github.com/apple/coreai-models/blob/main/skills/skills/working-with-coreai/references/guidance.md).

Core AI requires the newer platform/toolchain family; Apple describes iOS27,
macOS27 and Xcode27 requirements in its integration guidance. Locally the
iPhoneOS27.1 SDK contains CoreAI, and a tiny iOS27 Swift typecheck importing it
and BackgroundTasks passed. This proves SDK availability, not Chatterbox support
or successful model conversion. Older app deployment targets need a separate
availability-gated backend, not an unconditional deployment-target bump.
[Platform requirements](https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session).

Decision:investigate a separately versioned acoustic export first. Do not replace
our working library backend wholesale on the strength of an introductory demo.

### 3. Static shape buckets can improve execution, but padding is not free

Apple supports bounded enumerated input shapes for Core ML. Its ANE transformer
work also emphasizes layouts and avoiding excessive copies/intermediates.
Neither establishes the correct CFM attention mask for our model.
[Flexible shapes](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html),
[ANE transformer engineering](https://machinelearning.apple.com/research/neural-engine-transformers).

Hypothesis:test a small set of acoustic length buckets instead of executing every
utterance at1024frames. Validate all combinations and masked regions against the
same unpadded input. The old padded-ANE waveform cosine0.935 result and old GPU
aborts remain unqualified/stopped; a bucket is a new reviewed export, not clearance
to replay an old failed configuration.

### 4. The acoustic loop is the largest opportunity

Our current SynthRunner executes ten multilingual flow steps with two conditional/
unconditional model predictions per step. It builds host arrays and reads velocity
arrays around those calls. Repeated reference context is included on each chunk.
This matches the source model's iterative CFG structure.
[Upstream flow implementation](https://github.com/resemble-ai/chatterbox/blob/master/src/chatterbox/models/s3gen/flow_matching.py).

Hypotheses, to test individually:

1. Export one exact CFM step for an appropriate accelerator, then the unchanged
   ten-step trajectory. Compare captured tokens/conditioning/noise/intermediates.
2. Batch the two independent CFG branches if the graph permits it, preserving
   masks and guidance; then compare against the serial branches. Batch2 can
   increase peak memory and does not promise2× speed.
3. Keep Euler state and immutable inputs on the accelerator; avoid20host velocity
   round trips. Measure actual copies and execution before claiming their cost.
4. Validate a clean vocoder separately, including its transform/output scaling;
   a fast model with wrong PCM is a failed candidate.

Do not reduce solver steps, remove CFG, truncate the reference or remove the
watermark as an allegedly equivalent optimization. Each changes the experiment.
The encoder is bidirectional: blindly caching its prompt-only output can change
the result when generated tokens are appended. Cache only proven immutable work.

### 5. The GPU has newer tensor hardware, but correctness remains a gate

Apple documents neural accelerators within A19/M5 GPUs and Metal tensor APIs,
including quantized matrix operations and custom Core AI operators. These GPU
accelerators are distinct from the separate Neural Engine. Prefill and short
autoregressive decoding have different compute/bandwidth characteristics.
[A19/M5 GPU guidance](https://developer.apple.com/videos/play/tech-talks/111432/),
[Metal tensor operations](https://developer.apple.com/videos/play/wwdc2026/330/).

Hypothesis:after profiling, a targeted fused operator may help a hot acoustic or
decode path. It is not justification to replace every operation with custom Metal.
An upstream A19 audio-corruption report was ultimately traced to a third-party
shader synchronization race, not an MLX GPU bug. Its resolution reinforces
layerwise/device checks instead of assuming Mac success proves phone correctness.
[Resolved upstream investigation](https://github.com/ml-explore/mlx/issues/3702).
Keep our established TF32 setting and precision policies during comparisons.

### 6. Compile and cache carefully; some obvious optimizations already exist

MLX compilation can fuse work, but changing input shapes can trigger compilation.
Shapeless compilation has constraints for shape-dependent operations.
[MLX compilation](https://ml-explore.github.io/mlx/build/html/usage/compile.html).
Our KV cache already grows in256-position blocks and updates in place, matching
MLX's documented strategy. Do not count implementing that recommendation again
as a new speedup. Blindly compiling a loop with captured offsets/cache mutations
can freeze the wrong positions or compile every token.
[MLX KV guidance](https://ml-explore.github.io/mlx/build/html/usage/kv_cache.html).

Core ML persistent state avoids repeatedly passing large state tensors through
model I/O, but our decoder already caches K/V. Any new state/layout implementation
needs fixed-prefix logits/state checks; the failed old KV512 rewrite stays stopped.
[Core ML state](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html).

MLX reusable-buffer cache limits and live allocation limits are different. A
smaller buffer pool can prevent unbounded cached memory; it does not free live
weights. We already use a64MiB pool and release decode storage before acoustics.
[MLX memory semantics](https://github.com/ml-explore/mlx-swift/blob/main/Source/MLX/Memory.swift).
Tune any phase-boundary retention with measured peak footprint and latency.

### 7. Fewer chunk resets and bounded overlap are useful, but not5× proof

T3's local app-side measurement found merged narration paragraphs reduced RTF
from1.401→1.075(EN) and1.339→0.834(ES), versus four sentence units. This is
one paragraph per language; scalars and silence boundaries differ, so it is
preliminary evidence, not a pure segmentation or quality result.
Evidence:`chatterbox-segmentation-mac-182336` in shared release evidence.

Decision:add an opt-in library grouping policy that preserves source ranges,
speaker/voice, expression and structural breaks. Never merge across conflicting
directions. Benchmark with identical scalars and aligned source coverage, then
listen for continuity. Retain bounded request/context limits.

Next, permit at most one token-decoding worker and one acoustic worker with
bounded queued tokens/PCM. Different engines may overlap; shared memory bandwidth
and heat can erase the gain. Two complete model replicas are not the plan.
Preserve cancellation, seek, voice snapshots and cache identity across the split.
Measure full drained-window throughput, not merely time to first buffer.

### 8. Background inference needs explicit platform integration

The statement “iPhone cannot use the GPU in the background” is no longer an
adequate general rule. Apple supports GPU-requiring continued-processing tasks
on eligible devices. A task starts from a user action in the foreground, reports
progress and can be denied, queued, cancelled or expired. Check supported
resources and the relevant entitlement. This is a preparation-job opportunity,
not guaranteed unlimited invisible generation while a book plays.
[Continued processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados),
[GPU resource](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest/resources/gpu).

iOS27 also restricts background Neural Engine access and attributes its memory
to the app process. Apple documents a background-inference entitlement required
for background ANE access, including access outside a continued-processing task.
“ANE” therefore no longer automatically means unrestricted background narration.
[iOS27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes),
[background-inference entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference).

T3 owns capability/provisioning/lifecycle integration after the library exposes a
reviewed backend contract. Validate foreground, screen lock, task expiration,
route interruption and return separately. Existing audio playback permissions
are not evidence that inference resources are available.

### 9. Optimize energy per delivered audio, not the CPU percentage

At5× playback, an ideal worker needs about20% active duty to replenish a1×
reader. That is arithmetic, not an80% battery saving: accelerator power, resident
models, wakeups and conversion costs matter. Use cache high/low watermarks to
render bounded bursts, then stop preparing until needed. Cancel stale work early.
Never run a busy polling loop just to keep hardware awake.

Power Profiler supports physical-device energy analysis and thermal/display/
charging context. Apple notes that system power displays0while charging and
that Xcode pairing can prevent normal silicon sleep. Obtain an unplugged trace
for realistic duty-cycle measurements. Battery percentage over a brief render
is not a valid efficiency result.
[Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler),
[power optimization session](https://developer.apple.com/videos/play/wwdc2025/226/).

Record CPU/GPU/ANE execution, peak physical footprint (not just MLX bytes),
available memory, Low Power Mode, thermal trajectory, actual audio produced and
playback underruns. Normalize available energy/power metrics by generated audio
and listened audio. Preserve the thermal stop; faster cold bursts alone do not
establish sustainable throughput.

## Model-level alternatives and limits

The official **Nano** model is110M, English-only, with a distilled acoustic
decoder. Its advertised CPU real-time factor is the author's result, not an
iPhone measurement. Turbo is also English-only. Neither is a multilingual
checkpoint swap preserving the selected voice pipeline.
[Nano](https://huggingface.co/ResembleAI/chatterbox-nano),
[Turbo](https://huggingface.co/ResembleAI/chatterbox-turbo).

Official **Flash** uses block-parallel speech-token generation. Its headline
~9–13× real-time results use the CUDA-oriented path; its separate MacM4 MLX
figures are RTF0.778 and0.665(4-bit), short of our5× target. It is English-only.
It demonstrates a model-level parallel decoding direction, not a promised
Apple/iPhone speedup or an exact V3 replacement.
[Flash model card](https://huggingface.co/ResembleAI/chatterbox-flash).

If exact-weight engineering cannot reach the target, few-step multilingual
distillation or a block-parallel multilingual model is a separate model-development
project with new quality/feature/voice validation. Do not merely change an inference
step constant, remove emotion controls or silently choose an English model.

### Optional language downloads

Official V3 packs already exist for Spanish from Spain and Latin American Spanish.
They are language/region finetunes of the500M V3 family, not Turbo language packs.
Their T3 checkpoints are each approximately2.144GB FP32, plus approximately1.056GB
S3Gen; repository metadata gives the same S3Gen checksum for both regional packs.
That makes deduplicated acoustic downloads a concrete packaging opportunity, not
a model-compute reduction. Loading only one chosen pack at a time controls resident
model count, but does not shrink that pack's architecture.
[Spanish Spain](https://huggingface.co/ResembleAI/Chatterbox-Multilingual-es-es),
[Spanish Latin America](https://huggingface.co/ResembleAI/Chatterbox-Multilingual-es-mx-latam),
[official model sizes](https://huggingface.co/ResembleAI/chatterbox).

Pinned metadata-only audit (no model download):es-ES revision
`7262b364e3222ba9446c9289e7485eadc47ed902`;es-MX/LatAm revision
`27e595bf2fe7be0533ca299d9afafcde08b7cca7`.
Both S3Gen safetensors SHA256:
`4a46190f3dccc2230fbb3488a930bccc925862ee68f2662433dfcfe93ce6c2cb`.
Use one verified shared acoustic artifact where the exported backend also matches;
bundle the correct frontend with each T3 checkpoint. Never drop a different pack's
backbone beneath another pack's embeddings. Existing saved conditioning must be
validated per backend; do not assume cross-model voice identity equivalence.

The current official Turbo card still lists English. Targeted public Hub searches
and its official language-support discussion did not establish released official
Spanish Turbo checkpoints. This is a bounded search finding, not proof that no
community experiment exists. Generic multilingual instructions on a Turbo card
are not evidence that the Turbo weights support those languages.
[Official Turbo card](https://huggingface.co/ResembleAI/chatterbox-turbo),
[maintainer clarification](https://huggingface.co/ResembleAI/chatterbox-turbo/discussions/3).

Decision:design the library registry to describe locale, features, checkpoint,
frontend/acoustic dependencies, precision and approved runtime independently.
T3 can expose optional downloads from that registry. Spain/LatAm quality evaluation
is separate from reaching5× playback; do not promise faster inference from selecting
a single-language finetune or silently switch a selected voice's backend.

## Ordered experiments and acceptance

1. **Instrumentation and an8-bit contract.** Add numeric encoder/CFM/vocoder/
   watermark timings, prompt/generated lengths and physical footprint. Establish
   an independently reviewed quantized reference/fixture and named artifact/profile
   contract for an explicit8-bit trial; retain the existing profile/gates unchanged.
   Do not raise its tolerances simply to call a failed comparison a pass.
2. **Safe grouping.** Compare matched source and identical controls with new
   opt-in narration grouping. Include same-speaker dialogue boundaries, several
   voices, EN/ES and maximum allowed requests; preserve all source attribution.
3. **New acoustic backend.** Start with an exact one-step captured-input test;
   investigate Core AI/static shapes first, with a native-MLX alternative where
   conversion/layout support fails. Validate the full unchanged trajectory and
   vocoder before any phone run. Keep failed exports immutable.
4. **Bounded overlap.** One decoder plus one approved acoustic worker. Explicit
   generation identity and conditioning snapshots; cancellation/seek must not
   publish stale audio. Compare against serial with the same frozen requests.
5. **Controlled phone trial.** T3 integrates only a reviewed SDK profile/manifest.
   Test stock first; saved-voice conditioning stays private on the phone. Numerical
   checks, listening approval and sustained performance are separate outcomes.
6. **Sustained qualification.** Target aggregate RTF≤0.20 at1× playback, and
   report slow-window/percentile RTF rather than hiding difficult passages in an
   average. Include bounded10-minute playback once shorter checks pass, no
   serious thermal state, bounded memory/cache, cancellation and lock/unlock.
   Measure cold start separately. Unplugged energy testing follows stable speed.

This is a ranked plan, not evidence that this architecture can meet5× on iPhone.
The main next engineering effort belongs in acoustics and request granularity,
with8-bit memory reduction supporting—but not replacing—that effort.
