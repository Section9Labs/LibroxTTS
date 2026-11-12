# 0.9 evidence and reproduction

Base: local 0.8 candidate `e72a0cd`. Frozen public/planning/audio contracts originate
at 0.6.2. This directory is local candidate evidence, not release qualification.
See [implementation decisions](../implementation-09.md).

## Build and contracts

```sh
swift test
swift test -c release
swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members
python3 Scripts/check-public-api.py
```

Real-asset gates require explicit opt-in variables. Use disposable Core ML assets
because the existing preparation-recovery suite renames owned compiled generations.
`LIBROX_07_POCKET_ASSETS` and `LIBROX_08_POCKET_ASSETS` name that English/Spanish
installation, `LIBROX_07_CT_ASSETS` the pinned Plus installation,
`LIBROX_08_MLX_ASSETS` the pinned MLX installation, `LIBROX_07_AUDIO_OUTPUT` a fresh
recording directory, and `LIBROX_07_AUDIO_BASELINE` the frozen 0.6.2 recordings.
`POCKET_METALLIB` names the built MLX default.metallib if runner discovery needs it.

## Planning and preparation

Compile `docs/BroaderPlanning09.swift` with `swiftc -O` against each revision's
Release products (`-I PRODUCTS` plus `KokoroNarration.o`, `KokoroPronunciation.o`,
`PronunciationEnglish.o`, `KokoroCatalog.o`, `LibroxCTNative.o`). Run:

```sh
python3 Scripts/benchmark-08-planning.py OLD_PROBE NEW_PROBE --output planning-abba.json
```

This reuses the fingerprint/ABBA runner with ten new workloads. The older plain
and short controls use `docs/architecture-07/PlanningBaseline.swift` and
`docs/architecture-08/PlanningShort.swift` with the same objects/runner.

`docs/Preparation09.swift` instead links `PronunciationEnglish.o` and
`KokoroAudio.o`; place its executable beside the built resource bundles. It keeps
one dictionary alive while constructing four more and compares fresh versus
reset DSP instances in ABBA order with exact PCM equality. Dictionary timing is
separate baseline/candidate, not a multi-process ABBA statistical study.

`VoicePromptPreparation09Tests` is opt-in with `LIBROX_09_ASSETS` and
`LIBROX_09_PROMPT_OUTPUT`. It compares full-file SHA256-verified retained decoded
voice arrays with repeated decoding; every array must be equal.

## Backend sidecar

Build the same `Release09BenchmarkTests` against baseline and candidate runtime.
Preserve each complete Release product directory (including resource bundles).
The baseline here contains the new harness but unchanged 0.8 runtime. Run without
concurrent builds or other task-owned benchmarks:

```sh
python3 Scripts/benchmark-09-backends.py BASELINE_PRODUCTS CANDIDATE_PRODUCTS \
  --coreml-assets COREML_ROOT --mlx-assets MLX_ROOT \
  --work TEMP_RESULTS --output backend-abba.json
```

Use a fresh TEMP_RESULTS directory; the runner refuses to reuse an existing one.
The runner launches independent XCTest processes in ABBA order for Core ML,
MLX CPU and MLX GPU. Each process covers cold generation, fresh preview+generation,
two warm generations, a fixed book excerpt, voice/language switches and a 2 ms
synchronous receiver delay per frame. Raw PCM lives in TEMP_RESULTS; the committed
JSON includes hashes, sample counts, completed-chunk events and all observations.
First accepted frame and post-first frame-service percentiles are separate;
frame service excludes receiver delay. Preview time is reported separately.
Footprint is observer-sampled process memory, not a true system-wide peak.

## Full-model capacity experiment

`capacity-cache.patch` is an experiment applied to the actual runtime cache,
not an append-only benchmark. It was rejected because public mutable state references
no longer affect subsequent appends; all sixteen actual-model audio/event cases
passed. Production retains the original cache. Apply only in a disposable worktree, then rebuild
and run `CacheContract09Tests` and the backend sidecar against unchanged outputs.
The test compares cache append/prefill, retained snapshots, state restoration,
trim/reset and manual offsets on CPU/GPU. Exact seeded model PCM and completed
chunk events are required before treating timings as an optimization result.
Do not enable this patch in production merely because isolated appends are faster.
