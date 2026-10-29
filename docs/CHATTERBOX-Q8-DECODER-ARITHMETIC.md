# Q8 decoder arithmetic investigation

Status: the iPhone startup failure is reproduced and remains unresolved. None
of the counterfactuals below is selected by a production renderer. No threshold,
reference output, token bias, watermark or production compute policy changed.

## Physical replay

The isolated Q8 Replay Probe 0.2 (12) reproduced Librox 297's V2 failure on
Tachikoma before audio generation. The native cache snapshot/restore control was
bit-identical at all three decode steps. Restoring the frozen CPU prefill cache
did not recover `es.decode.2`: the unconditional leader was 4205 instead of 6472.
Its signed margin between the expected leaders was -0.00019598007; the CPU
reference margin is +0.00024795532. The CPU-restored comparison measurements
match the Mac replay at all three steps. Full cross-device logits were not
exported, so this is not a claim of complete cross-device bit identity.

The probe process was verified, terminated and confirmed absent. Its app-scoped
idle hold ended. Librox and private voice conditioning were not accessed.

Evidence root (local, not a public model distribution):

`/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01`

- `prefill-cache-replay-phone-v01/report.json`: physical result.
- `prefill-cache-replay-phone-v01/process-after.json`: owned process absent.
- `prefill-cache-replay-mac-v01/report.json`: matching controlled failure.

## Controlled arithmetic fixtures

The Mac-only CLI accepts `local-q8-rope-export` and
`local-q8-rope-counterfactual` configurations. The CPU exporter and GPU consumer
must run in **separate fresh processes**, with `MLX_ENABLE_TF32=0` and
`CHATTERBOX_SYNTH_SEED=42`. It does not generate audio.

The exporter requires both traced and untraced CPU execution to reproduce all
18 frozen logits bit-for-bit. Its hooks retain arrays without evaluation. It
also snapshots CPU state after `es.decode.1`, restores offset95/capacity256 and
requires a one-step `es.decode.2` CPU replay to be bit-identical. It exports the
60 actual query/key inputs and RoPE outputs at position95, CPU frequency arrays,
all-position CPU trig tables and the 30-layer offset95 cache.

The consumer pins the exact exported artifact, checks the complete key set,
shapes, dtypes and finiteness, and retains resource guards. The verified artifact
is `cpu-rope-offset95-v02.safetensors`, SHA256
`e3155186f9f00f2c1c8409c35f2532bd6ea29c81798256bac68b61f383adc125`.
Its CPU receipt is `rope-cpu-export-v02/report.json`.

MLX's CPU RoPE fallback rounds trig values to half, then performs separate half
products/additions. Its GPU fast kernel rotates in float and rounds the result.
On identical actual CPU q/k and frequency inputs, GPU fast RoPE differs in
26,136 of 122,880 half values. The CPU-table/separate-half-operation diagnostic
matches all 122,880 bits. This proves a local semantic difference, **not** that
RoPE alone causes or fixes the failed ranking. GPU-initialized versus
CPU-initialized frequencies are tested separately.

The first combined CPU/GPU-process experiment (`rope-counterfactual-v01`) is
retained but its full-model comparisons are excluded from causal conclusions.
MLXNN has a shared compiled SiLU closure, and source review identified possible
CPU-first graph-cache reuse across Swift device scopes. This execution-stream
hypothesis has not been independently proved. The fresh GPU-only process
restores the original V2 native-prefill 18/18 result; all later comparisons use
separate-process export/replay.

## Results and limits

`rope-gpu-counterfactual-v02/report.json` and
`arithmetic-gpu-counterfactual-v03/report.json` retain the frequency, rounding,
materialized-attention, explicit-norm and uncompiled-SiLU controls.
`arithmetic-gpu-counterfactual-v04/report.json` adds dense FP32-accumulation
projection controls with the same decoded-half Q8 weights. Dense controls have
a different footprint; they are not packed-Q8 memory or speed evidence.
The final hardened consumer was rerun as
`arithmetic-gpu-counterfactual-v05/report.json`: all 11 controlled target
predictions still fail. `arithmetic-diagnostic-source-v05/manifest.json` records
the executed binary and source hashes. Release validation passed 10 XCTest
cases plus the existing library suite (57 reported Swift Testing cases,
including three skipped opt-in integrations).

| GPU-only arm | Native-prefill gates | CPU95 target margin |
| --- | ---: | ---: |
| Unchanged V2 | 18/18 | -0.0010609627 |
| Fast RoPE with CPU frequencies | 18/18 | -0.0012722015 |
| CPU-table half RoPE | 17/18 | -0.00073957443 |
| Materialized attention only | 18/18 | -0.0005893707 |
| Half RoPE + materialized attention | 18/18 | -0.0005054474 |
| Half RoPE + explicit norm | 18/18 | -0.00052547455 |
| Half RoPE + uncompiled SiLU | 17/18 | -0.00073957443 |
| All three fallback sequences + half RoPE | 17/18 | -0.0005054474 |
| Dense FP32 accumulation, other operations native | 18/18 | -0.0009846687 |
| Dense FP32 accumulation + half RoPE | 17/18 | -0.0009942055 |
| Dense FP32 accumulation + all fallback sequences | 17/18 | -0.000009059906 |

Every CPU-prefill replay also still fails the same target ranking. A smaller
error, a near-zero margin or native-prefill 18/18 alone does not clear a
correction. GPU reductions, exponentials and matmuls remain GPU implementations
in the fallback-sequence controls; these are not exact CPU execution.

The next justified experiment is same-input primitive replay at the validated
CPU95 boundary: projections, norm, attention, activation and final head. Keep
the untouched V2 CPU93/95 failures as controls. Do not repeat unchanged phone
tests or promote one of these negative controls. A later correction needs
independent review and fresh physical validation before app integration.

Sustained narration, recorded-voice listening acceptance and whole-pipeline
RTF<=0.20 remain separate unresolved goals. These fixed-input decoder
experiments provide no audio-quality, battery or end-to-end speed evidence.

## Same-input primitive stage

The CLI now also supports `local-q8-primitive-export`,
`local-q8-primitive-replay` and `local-q8-primitive-cpu-replay`. CPU export and
GPU replay remain separate fresh processes. The fixed CPU artifact is
`cpu-primitives-offset95-v02.safetensors`, SHA256
`ba0a7add438d5f1326ce7aa541339cee4b2d3d3d973c3f56ddfb6019b00d38d4`.
It contains 694 finite, shape-checked tensors for the public Spanish target.

The CPU exporter again reproduces all 18 frozen outputs both without and with
instrumentation, plus the restored CPU95 target, bit-for-bit. It wraps 211
linear modules and 60 block norms. The immutable final norm is observed through
a hook rather than replaced. Attention records the entire active 96-position
K/V prefix; arrays are copied into independent host storage immediately after
the target evaluation, before subsequent cache updates. All hooks are Mac-only
and nil during normal inference.

Two failed harness attempts remain preserved: CPU export v01 attempted to
replace the final norm despite its immutable registration; GPU replay v01
incorrectly included RoPE leaves in its linear/norm schema. The versioned fixes
use the final-norm hook and explicitly select the 272 measured linear/norm
modules. RoPE remains covered by its separate replay. Neither failure changed
production arithmetic or numerical gates.

Successful receipts are `primitive-cpu-export-v02/report.json`,
`primitive-gpu-replay-v02/report.json` and `primitive-cpu-replay-v01/report.json`.
The GPU report has 873 measurements and reproduces the known unchanged native18,
CPU93 and CPU95 controls, including their failing signed margins.

| Same CPU inputs, native GPU operation | Values compared | Half-rounded differences |
| --- | ---: | ---: |
| 210 packed projections | 798,720 | 190,760 |
| 61 norms | 124,928 | 8 |
| 30 attention outputs | 61,440 | 50 |
| 30 activated MLP products | 245,760 | 9 |
| Final FP32 head | 16,388 | 0 |

The same-input final head is bit-identical in FP32, including both expected
leaders and margins. This rules out head arithmetic alone for this particular
fixed input. It does not rule out upstream hidden-state differences.

The CPU-local materialization control is important: all 211 linear outputs are
bit-identical to their captured CPU outputs. Thus the large projection
discrepancy is not explained by merely copying these inputs. Changing CPU
projection arithmetic to FP32 matmul followed by a half cast changes 190,776
of 798,720 half outputs, maximum absolute difference 0.00390625. GPU dense-half
and dense-FP32 controls have similar aggregate disagreement counts against the
CPU-half capture. **Similar counts do not establish pairwise CPU-FP32/GPU
identity or which backend is more accurate.**

The next stage is preregistered in `exact-dot-study-v01-preregistration.json`:
32 uniformly spaced output rows from every transformer projection, both lanes,
13,440 scalar outputs. Execute full original backend shapes before selecting
rows, so sampling does not itself change dispatch. Save paired output bits.
Finite half operands are integer multiples of 2^-24, allowing exact integer
dot sums in units of 2^-48 and direct nearest/ties-to-even half rounding.
Compare full products with half-rounded products as a policy fingerprint;
Double/Kahan is a cross-check, not the half-midpoint arbiter. Validate the
rounder on normal/subnormal, tie, cancellation and overflow boundaries.

Characterize the CPU-half backend's numerical policy before proposing any
correction. Do not select a new reference from whichever candidate happens to
pass. All existing references and gates remain immutable, and no primitive
discrepancy by itself establishes responsibility for the final ranking.

Release validation after these hooks passed all 10 focused MLX XCTest cases;
the complete log is `primitive-release-tests-v01.log`. No audio or phone work
was performed in this stage.

## Preregistered exact-dot results

The sampling rule above was evaluated without changing membership: all 210
matrices, 32 uniform output rows, both lanes, 13,440 scalar outputs and
19,660,800 products. CPU and GPU operators retained their full original shapes.
All 798,720 CPU-half outputs reproduced their captured values, and all
9,830,400 sampled reconstructed weight bits agreed across CPU and GPU.

The independent Python analyzer uses integer sums in units of 2^-48 and direct
nearest/ties-to-even half rounding. It passed 253,962 arithmetic/ULP checks,
including exhaustive finite-half decoding/inversion and adjacent midpoint
tests. It refuses optimized Python that would remove assertions. Input hashes,
membership, shapes, finiteness, preallocation size limits and bounded runtime
are checked before accepting the study.

| Method, identical sampled operands | Different from exact rounded dot | Maximum half-ULP distance | Maximum absolute error |
| --- | ---: | ---: | ---: |
| CPU-half | 3,138 / 13,440 | 436 | 0.00390625 |
| CPU-FP32 then half | 25 / 13,440 | 1 | 0.000244140625 |
| Canonical packed GPU | 7 / 13,440 | 1 | 0.00006103515625 |
| Dense-half GPU | 6 / 13,440 | 1 | 0.000244140625 |
| Dense-FP32 GPU then half | 24 / 13,440 | 1 | 0.000244140625 |

The 436-ULP CPU case is near zero, with absolute error approximately
0.00002599; it is not the maximum-absolute-error case. CPU-half agrees less
often with exact rounded dot arithmetic on this sample. This does not identify
an undocumented backend mechanism or establish full-model/audio quality.

Paired GPU-versus-CPU-FP32 differences are 28 (packed), 27 (dense-half) and 17
(dense-FP32), each at most one half ULP. Kahan matches every sampled exact
rounded result, but integer arithmetic remains the reference. The
half-rounded-product fingerprint disagrees with CPU-half on 5,179 samples;
it must not be used as a guessed replacement kernel.

Artifacts and exact executed-source manifests are under
`exact-dot-cpu-export-v01`, `exact-dot-gpu-export-v01`,
`exact-dot-cpu-source-v01`, `exact-dot-gpu-source-v01` and
`exact-dot-analyzer-source-v01`. Detailed paired bits and membership are retained
in `exact-dot-analysis-v01.json`. The implementation is in
`Experiments/Q8ExactDotStudy/exact_dot.py` and `ExactDotExport.swift`.

The next diagnostic is preregistered in
`certified-projection-counterfactual-v01-preregistration.json`: independently
certify FP64 projection accumulation against integer sums, resolving ambiguous
half-rounding intervals exactly, then replace only transformer projections in
an offline CPU counterfactual. Preserve the original CPU nonprojection
operations, native18 and CPU93/95 controls. Keep old-oracle parity and proposed
exact-projection fidelity separate. This does not create or approve a new
oracle, inference profile or phone build.

## Certified projection helper: certification stage

`CertifiedHalfProjection` is a throwing, Mac-only offline helper. It computes
CPU FP64 dots on the original half operands, using an outward-inflated
gamma_K accumulation-error interval. It accepts a rounded half only when both
interval endpoints round to identical bits; ambiguous cases use exact Int128
summation and direct nearest/ties-to-even rounding. Finite half coefficients
bound the complete integer sum below 2^92. Operand/maxima invariants, monotonic
180-second budget, cancellation and resource checks remain active, including
checks every 64 output columns before potentially expensive exact work.

This certification assumes ordinary IEEE binary64 accumulation in CPU BLAS.
The local Float64 backend dispatches to CBLAS DGEMM; that opaque implementation
assumption is stated explicitly. Tests exercise its cancellation and subnormal
conversions, direct Double-to-half rounding at every half boundary, exact
normal/subnormal/tie/overflow behavior, maximum-length integer sums and forced
ambiguity resolution. All 16 focused Release tests passed.

On the stored Spanish target-step operands, the certification study produced
798,719 interval-certified outputs and one exact fallback. All 13,440
independent integer-reference samples matched bit-for-bit; all 798,720 original
CPU-half control outputs also reproduced their captured bits. The fallback was
recorded at `tfmr.layers.7.mlp.down_proj`, flattened input row1, output652.
It is a rounding-boundary ambiguity, not a claim that the exact dot is a tie.

`certified-projection-samples-v01` retains the initial result;
`certified-projection-samples-v02` adds explicit boundary audit data. Their 210
tensor payloads are bit-identical, despite different container hashes. The
comparison is retained as `payload-comparison.json` in v02. Exact source/binary
manifests are under `certified-projection-source-v01` and `-v02`.

**The full-model precision intervention has not run.** These are diagnostic
projection outputs, not an app oracle, selected model or device qualification.
The next stage adds an eager-native-FP16 negative control with identical host
copy boundaries, then tests a projection-only certified arm while keeping
original CPU nonprojection semantics. Require bit-identical eager-native18 and
CPU93/95 trajectories before attributing differences to precision.

`projection-counterfactual-implementation-controls-v01.json` defines the
per-run first-error latch for nonthrowing Linear callbacks: short-circuit later
projections and throw immediately after `model.logits`, before evaluating or
accepting output. Forced first/middle/last failures and cancellation must prove
that no successful receipt or artifact can be produced. No native-arithmetic
fallback is permitted. All old references, failures and gates remain unchanged.
