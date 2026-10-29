# Chatterbox footprint experiment, 29 October 2026

Initial evaluation: experimental Mac listening candidate only. The later library
implementation adds a separately named experimental Q8 profile with an independent
intended-Q8 reference; see CHATTERBOX-LIBRARY-OPTIMIZATION-HANDOFF.md. Original
profile gates remain unchanged; no app pin or phone installation changed.
The SDK owner owns this work; T3 owns app integration.

## Measured comparison

Four short public-stock-conditioned English/Spanish passages, calm and dialogue.
Same exact frontend prefixes, request settings, sampler seed42, acoustic noise42,
CPU CoreML acoustics and Perth watermarker. Each arm runs in a separate optimized
Mac process. The baseline passes all18 existing fixed-prefix precision checks.

| Measure | Current mixed FP16 | Local Q8 G64 |
| --- | ---: | ---: |
| Resident decoder parameters, decimal MB | 1040.45 | 568.59 |
| Process-lifetime peak MLX allocation, decimal MB | 1721.23 | 1154.64 |
| Fixed-prefix decode prediction median, ms | 8.10 | 6.71 |
| Total render wall, seconds | 18.20 | 17.64 |
| Generated audio, seconds | 21.80 | 22.12 |
| Existing strict precision checks passed | 18/18 | 3/18 |
| Both CFG lanes retain top1 | 18/18 | 17/18 |

Decoder parameter reduction:45.35%. This is not a45% whole-app memory reduction.
MLX peak includes temporary allocations and is not process RSS; CoreML allocations
are outside these MLX numbers. Different generated lengths and active desktop
workload make whole-generation speed preliminary. Acoustics dominate the remaining
wall time. No iPhone performance, thermal or cloned-voice acceptance is established.

## Exact local candidate

Source backbone SHA256:
`3df864ea174ee38478910c9b03358b36f2241166844bd5458c9b2f917e110ab0`.
The source FP32 projections are first rounded exactly as the existing baseline's
mixedFloat16Accurate loader does. MLX Swift0.32.3 then affine-quantizes only210
transformer projections to8bits/group64, with FP16 scales/biases. Projection-output
dtype checks enforce FP16. Existing accurate activation arithmetic remains.
All62 FP32 normalization/output-head arrays remain bit-identical (raw-byte audit).

Serialized candidate:568662708bytes, SHA256
`231647ebb4deedad901c46cf3d7ca1e0fa70371b461c934c14dc63f16ec69017`.
This is distinct from the linked community checkpoint. Existing production gates
are neither widened nor bypassed by the production renderer. The Mac diagnostic
explicitly records candidate failures while permitting the authorized listening
experiment. Quality acceptance remains Matt's decision and does not alone clear
production numerical, device or sustained-narration gates.

## Linked candidate compatibility stop

Repository: https://huggingface.co/smdesai/Chatterbox-Multilingual-TTS-8bit

Revision:`79c221c69773d0aee69bf66f276c1fb7677e0b41`.
Full file:1326273655bytes, SHA256
`54ec7ec9738d247867c63fcee7fc2d4976764045d5381bf5264afb7309eef38c`.

Packed format is structurally compatible with affine MLX Q8 group64. However,
all62 unquantized normalization/head tensors and the checked text/speech embedding
rows differ from our current V3 assets. These differences are independent of
quantization. First English prefill oracle max error8.959, relativeL2 .3299,
both-lane top1false. A mixed-checkpoint render was stopped and quarantined;
its audio must not be used to judge that repository. The diagnostic now enforces
oracle-only operation for this foreign checkpoint. A faithful full-model trial
requires its own compatible frontend/acoustic pipeline; never swap just its
backbone under our current frontend. Its FP32 affine metadata also promotes
projection outputs/KV toFP32, a different precision/memory policy.

## Other smaller published candidates

- https://huggingface.co/mlx-community/chatterbox-4bit advertises multilingual
  weights around607MB. Compression, not a distilled smaller architecture.
- https://huggingface.co/groxaxo/chatterbox-multilingual-MLX-Q8-G64 and its Q6
  sibling publish EN/ES comparison evidence and explicit limits. Their whole-model
  format/precision policies differ from our hybrid library and need independent
  reproduction. Their metrics are author-reported, not our acceptance.
- https://huggingface.co/ResembleAI/chatterbox-turbo is a350M English model with
  a distilled one-step acoustic decoder. It is not a multilingual replacement.

## Reproduction and evidence

Build:`swift build -c release --product librox-chatterbox-quantization-probe`.
Run:`MLX_ENABLE_TF32=0 CHATTERBOX_SYNTH_SEED=42` followed by that executable
and one owned configuration JSON. Separate fresh output directories are required.
The export profile produces the local packed artifact plus per-tensor error data.
The extractor script verifies the linked source SHA and never executes remote code.

Owned durable receipts/configs/model artifacts:
`/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01`.
Generated-only listening copies:
`/Users/matt/.codex/outputs/chatterbox-q8-listening-2026-10-29`.
Both contain `comparison.json`; individual arm reports include raw tokens, prefix
hashes, timings, memory, peaks and every precision check. Source/voice files are
not copied into the listening output.49 existing library tests passed.
Independent code review found no blocker for this bounded Mac experiment;
it did not certify quality or phone readiness. No phone was accessed.

## Local Q4 follow-up

The same exact-baseline conversion now also supports affine Q4 group64 with
FP16 metadata. All210 projection output dtype checks pass, and a raw-byte audit
again confirms all62 FP32 normalization/output-head tensors are unchanged.
Serialized file:317004160bytes, SHA256
`b797748abce77268bc2502f9bc9c2bf7da4b77deb47ceb704f31d816016fc32c`.

Same four public stock requests, exact matching frontend prefixes/settings/seeds:

| Measure | Q4 G64 |
| --- | ---: |
| Resident decoder parameters, decimal MB | 316.93 |
| Reduction versus current mixed FP16 parameter memory | 69.54% |
| Process-lifetime peak MLX allocation, decimal MB | 902.98 |
| Fixed-prefix decode prediction median, ms | 7.70 |
| Total render wall, seconds | 20.08 |
| Generated audio, seconds | 21.92 |
| Existing strict precision checks passed | 0/18 |
| Both CFG lanes retain top1 | 11/18 |

This small sample establishes no end-to-end speed benefit for Q4. Generated tokens
and durations differ; unchanged acoustic execution also varied, so this is not a
controlled kernel-level conclusion or an iPhone benchmark. Numerical drift is
larger than Q8; subjective quality remains unjudged. Generated Q4 WAVs and their
receipt are beside the earlier pairs in the listening directory. Q8 remains the
leading compression candidate, but neither clears the existing production gate.

## App integration boundary

These local candidates retain the current V3 frontend, voice format and Core ML
acoustics. They need no new Core ML conversion. A usable phone profile still needs
a separately reviewed library loader, pinned artifact/schema/profile identities,
precision validation and device checks. T3 would then update the app manifest,
SDK pin and cache identity. The current app's native/backbone-f32.safetensors and
the SDK's pinned FP32-source loader cannot simply be replaced by packed Q4/Q8
files. The foreign smdesai checkpoint remains a different compatibility problem.
