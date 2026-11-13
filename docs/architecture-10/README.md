# Reproducing the 1.0 measurements

Read [the implementation report](../implementation-10.md) for results and limits.
The immutable production baseline is `07fcf437004027f58ad8bb16de7877d0ee74a9a8`
(v0.9.0). Production candidate source is `f1d31fa`; later commits add measurement
receipts, tooling and documentation. Each main receipt records executable hashes.
All measurements use the same pinned asset bytes and backend for each pair.

## Build and contract checks

Use isolated baseline and candidate checkouts. Build with Swift Build so MLX's
Metal resources are present. The local runs used Xcode 27.2 / Swift 6.4.2 on an
M3 Ultra, macOS 27.0.1. Swift 6.3 and remote CI are not qualified by these runs.

```sh
swift test --build-system swiftbuild
swift test --build-system swiftbuild -c release
swift package --build-system swiftbuild dump-symbol-graph --minimum-access-level public --skip-synthesized-members
python3 Scripts/check-public-api.py
python3 -m compileall -q Benchmarks/Narration Scripts
```

Run the same build commands in the 0.9 checkout. For the extended Max MLX audio
matrix only, copy the candidate's `Tests/PocketTTSCoreMLTests/Release10MLXAudioTests.swift`
into the baseline test target before building. It calls existing APIs; do not copy
candidate production files. Remove that test source after building the baseline
products. Existing Core ML and Plus probes already exist in 0.9. This preserves
baseline runtime code and enables identical requests/recording machinery.

The two generic unsigned example builds and API inventory commands are also in
`.github/workflows/swift.yml`. `validation.json` records completed suite counts,
log hashes, environment, dictionary coverage and focused tests. Opt-in model tests
skip in the ordinary suites; their separate actual-model receipts are required.

## Mac measurements

Set the following paths for your machine. Use a fresh output directory for each
run, keep prepared model and asset directories separate from host application data,
and do not run build/audio/benchmark jobs concurrently. Timings are descriptive
ABBA medians, not confidence intervals. The original host was shared with other
work, so GPU variability is explicitly retained.

```sh
BASELINE_PRODUCTS=/path/to/baseline/.build/out/Products/Release
CANDIDATE_PRODUCTS=/path/to/candidate/.build/out/Products/Release
COREML_ASSETS=/path/to/verified/pocket-coreml-assets
MLX_ASSETS=/path/to/verified/pocket-mlx-assets
PREPARED_MODELS=/path/to/prepared-coreml-models
BASIC_ASSETS=/path/to/verified/basic-assets
RUN_ROOT=/tmp/libroxtts-10-reproduction
mkdir -p "$RUN_ROOT"

python3 Scripts/benchmark-10-preparation.py "$BASELINE_PRODUCTS" "$CANDIDATE_PRODUCTS" \
  --work "$RUN_ROOT/preparation" --output "$RUN_ROOT/preparation-abba.json"
python3 Scripts/benchmark-10-pronunciation.py "$BASELINE_PRODUCTS" "$CANDIDATE_PRODUCTS" \
  --work "$RUN_ROOT/pronunciation" --output "$RUN_ROOT/pronunciation-abba.json"
python3 Scripts/benchmark-10-profile.py "$BASELINE_PRODUCTS" "$CANDIDATE_PRODUCTS" \
  --assets "$COREML_ASSETS" --models "$PREPARED_MODELS" \
  --work "$RUN_ROOT/profile" --output "$RUN_ROOT/profile-abba.json"
python3 Scripts/benchmark-10-backends.py "$BASELINE_PRODUCTS" "$CANDIDATE_PRODUCTS" \
  --coreml-assets "$COREML_ASSETS" --mlx-assets "$MLX_ASSETS" \
  --work "$RUN_ROOT/backends" --output "$RUN_ROOT/backend-abba.json"
python3 Scripts/validate-10-audio.py "$BASELINE_PRODUCTS" "$CANDIDATE_PRODUCTS" \
  --coreml-assets "$COREML_ASSETS" --mlx-assets "$MLX_ASSETS" \
  --work "$RUN_ROOT/audio" --output "$RUN_ROOT/audio-matrix.json"
python3 Scripts/validate-10-basic.py "$BASELINE_PRODUCTS" "$CANDIDATE_PRODUCTS" \
  --assets "$BASIC_ASSETS" --work "$RUN_ROOT/basic" --output "$RUN_ROOT/basic-audio.json"
```

The final `backend-coreml-final.json` uses `benchmark-10-backends.py --backends coreml`
after the native-voice guard. The earlier three-variant `backend-abba.json` remains
the MLX receipt and capacity ablation; MLX production code did not change between
those receipts. The capacity variant requires reconstructing the archived
experiment, not enabling an option in production. See [runtime decisions](runtime-decisions.md).

For Plus, run the existing
`PocketTTSCoreMLTests.Release07AudioTests/testPlusTraceAndPCMContractAgainst062`
with `LIBROX_07_CT_ASSETS`, `LIBROX_07_AUDIO_OUTPUT`, and immutable
`LIBROX_07_AUDIO_BASELINE` fixtures. Both revisions use the same recorded initial
noise; fresh unseeded noise is not a valid exact comparison. `plus-audio.json`
records six exact outputs, including traced progress. Basic compares WAV format
and PCM data, excluding incidental file metadata.

Focused checks run in a fresh process with the selected product's Metal library:

```sh
export POCKET_METALLIB="$CANDIDATE_PRODUCTS/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
LIBROX_10_ROTARY_OUTPUT="$RUN_ROOT/rotary-ablation.json" \
  xcrun xctest -XCTest PocketTTSMLXTests.RotaryExecution10Tests \
  "$CANDIDATE_PRODUCTS/PocketTTSMLXTests.xctest"
LIBROX_10_LIFETIME_ASSETS="$COREML_ASSETS" LIBROX_10_LIFETIME_OUTPUT="$RUN_ROOT/repeated-render-memory.json" \
  xcrun xctest -XCTest PocketTTSCoreMLTests.Release10LifetimeTests \
  "$CANDIDATE_PRODUCTS/PocketTTSCoreMLTests.xctest"
```

`FlowCompilation10Tests` is an opt-in research probe, not an engine setting. Its
first CPU call can take minutes. Exact flow outputs do not certify full-engine
compiled audio; production compilation stays disabled.

## Physical device and final score

Follow [the isolated device harness](../../Scripts/Qualification10/README.md).
`Qualification10/run.py` performs fresh-setup ABBA, warm ABBA, and a completed
30-minute candidate foreground soak. It refuses bundle IDs outside the two task
apps. `device-final.json` retains those results and executable hashes.
`compare-10-device.py` separately compares complete 12-case matrices and baseline /
candidate soak hashes, events and memory. It does not treat unequal soak durations
or thermal histories as a speed comparison. `device-qualification.json` retains
that summary and every sampled row.

After all required receipts are present:

```sh
python3 Scripts/score-10.py --evidence docs/architecture-10
```

The cold release goal counts fresh device preparation, as required by the original
design. Installed/prepared-pack Mac startup is supplemental. Never substitute that
smaller number for true cold startup. The scorecard retains misses and regressions.
No iPhone, background/lock playback, battery energy or human listening certification
is implied by an exact foreground iPad run. Uninstall only the two qualification
apps after collecting their completed outputs.

## Evidence index

| Receipt | Role |
|---|---|
| `scorecard.json`, `targets.json` | Original numerical goals, observations, misses and limits |
| `source-revisions.json`, `validation.json` | Exact source revisions, contract/build/test coverage |
| `preparation-abba.json`, `pronunciation-abba.json` | Final preparation gains and warm/short controls |
| `profile-abba.json`, `backend-coreml-final.json` | Final guarded Core ML timings and sampled memory |
| `backend-abba.json` | Final MLX timings; capacity versus rotary-only ablation |
| `audio-matrix.json`, `plus-audio.json`, `basic-audio.json` | Final admitted runtime's 92 exact Mac comparisons |
| `rotary-ablation.json` | Admitted component's isolated final CPU/GPU timing |
| `repeated-render-memory.json` | Final guarded isolated Mac memory regression |
| `device-final.json`, `device-qualification.json`, `device-soak-binaries.json` | Final completed physical iPad ABBA and soak evidence |
| `device-memory-investigation.json` | Baseline leak reproduction and rejected intermediate fixes |
| `audio-cache-experiment.json`, `backend-capacity-experiment.json`, `experiments/` | Earlier capacity prototypes; not the final runtime |
| `flow-compilation-experiment.json` | Research-only flow compilation, not full-engine admission |

Raw local logs and audio produced for this task remain under `/tmp/libroxtts-10`
(and the immutable 0.9/0.6.2 fixture directories noted by the probes). Temporary
storage is not a durable artifact service; the checked-in receipts contain sample
hashes, counts, events, timings and executable identities. Reproduce the probes to
regenerate audio; no model weights or personal host-app data are committed.
