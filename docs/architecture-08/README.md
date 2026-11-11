# 0.8 evidence and reproduction

Base: local 0.7 candidate `dee2b49`. Frozen public/planning/audio contracts were
captured from 0.6.2. This directory describes a local candidate, not a release.
See [the implementation record](../implementation-08.md) for decisions and limits.

## Gates

```sh
swift test
swift test -c release
swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members
python3 Scripts/check-public-api.py
```

Ordinary tests explicitly skip external model suites. To exercise the additional
0.8 renderer parity/recovery tests, provide `LIBROX_08_POCKET_ASSETS` (a disposable,
verified English/Spanish Core ML installation), `LIBROX_07_AUDIO_BASELINE` (the
frozen 0.6.2 recordings), and `LIBROX_08_MLX_ASSETS` (verified MLX English assets).
Set `POCKET_METALLIB` to the build's MLX `default.metallib` when needed by the
test runner. Filter `NarrationBackendParityTests|PreparationRecoveryTests`.
The recovery test deliberately renames a compiled generation, so never point it
at an installation in use by a host application.

The unchanged `Release07AudioTests` additionally requires
`LIBROX_07_POCKET_ASSETS`, `LIBROX_07_CT_ASSETS`, and a fresh
`LIBROX_07_AUDIO_OUTPUT`. Compare output with `Scripts/compare-07-audio.py`.
Do not regenerate baseline fixtures with the candidate runtime.

## Planning

Build both revisions in Release. Compile the same
`docs/architecture-07/PlanningBaseline.swift` with `swiftc -O`, using each
revision's product directory for `-I` and its objects `KokoroNarration.o`,
`KokoroPronunciation.o`, `PronunciationEnglish.o`, `KokoroCatalog.o` and
`LibroxCTNative.o`. Then run, after builds and inference have finished:

```sh
python3 Scripts/benchmark-08-planning.py BASELINE_BINARY CANDIDATE_BINARY --output planning-abba.json
```

For the independent short control, compile `PlanningShort.swift` against the same
two revisions and pass `--scope 'Already-fitting source units; ten warmups and
fifty samples per case per process; ABBA'`. The long-input probe has three samples
per case; the short control has fifty after ten warmups. Both require exact
plan fingerprints and record binary hashes. Complete-plan differential tests
cover fields beyond those fingerprints.

## Inference

`Scripts/benchmark-08-plus.py --help` describes the controlled 0.6.2/0.7 Plus
baseline. It builds both CT revisions with identical flags, runs two ABBA blocks,
and compares all PCM bytes with saved initial noise.

For the opt-in unchanged-model profile and isolated capacity-cache experiment,
build Release first, then set `LIBROX_08_INFERENCE_EXPERIMENT=1`, `POCKET_ASSETS`,
`POCKET_METALLIB`, and `LIBROX_08_INFERENCE_OUTPUT` to a new JSON destination:

```sh
swift test -c release --skip-build --filter release08InferenceProfileAndCacheExperiment
```

Run this alone. It records six seeded English renders and 24 cache observations.
The cache prototype is not integrated into model inference. Checkpoint intervals
include lazy evaluation and must not be interpreted as pure graph execution
times. CPU/GPU outputs are checked for repeatability within each backend, not
cross-backend numerical equality. No device, energy or listening qualification
follows from these shared-Mac results.
