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

## Full-model projection-only counterfactual

`projection-counterfactual-v01/report.json` completed the preregistered three
CPU arms under one monotonic 180-second budget. Original and eager-native
FP16 arms have byte-identical logits in all 22 conditions (native18 plus CPU93
three-step and CPU95 single-step replays). Their caches are bit-identical at
both measured boundaries. This validates the host-copy negative control.

Replacing only the 210 transformer projections with certified arithmetic,
while retaining every original CPU nonprojection operation, changes the
unconditional target leader from 6472 to 4205:

| `es.decode.2` condition | Original/eager signed 6472-minus-4205 | Certified projection-only |
| --- | ---: | ---: |
| Native trajectory | +0.00024795532 | -0.00037956238 |
| Original CPU93 incoming cache | +0.00024795532 | -0.00089120865 |
| Original CPU95 incoming cache | +0.00024795532 | -0.0004925728 |

Projection arithmetic alone is therefore sufficient to cause this ranking
flip, including when inherited state is fixed. It does not explain every GPU
discrepancy or qualify a new reference. The certified arm passes 19/22 old
comparisons; only the three target conditions reject. It produced 150,957,134
interval-certified outputs and 946 exact resolutions. Per-condition logits,
both lane comparisons, boundary cases and cache drift are preserved.

Original, eager and certified arm times were approximately 2.78, 2.98 and
10.90 seconds. These are offline CPU diagnostic times, not narration RTF or a
phone performance result. Immutable FP64 prepared weights are reused inside
one arm, with incremental allocation guards; their larger residency is not a
mobile footprint claim.

The per-run error latch checks before construction, before evaluation and
after evaluation, and increments acceptance only afterward. Failed arms are
discarded. The atomic completed report is the final success commit; status
alone is insufficient. All 21 focused Release tests passed, including forced
first/middle/last projection failures, actual mid-run/preconstruction/late
cancellation, and cached-versus-uncached prepared-weight equivalence.

The next bounded study is preregistered as
`gpu-policy-factor-study-v01-preregistration.json`: all four combinations of
native/canonical-FP32 prefill and native/CPU-table-half RoPE, with the same
two-row decode kernel. Use a fresh GPU-only process per arm. For a fixed RoPE
mode, restored CPU93/95 outputs must be bit-identical across prefill policies,
where prefill is inactive. Compare every condition against its matching
certified CPU diagnostic condition and the unchanged old oracle, retaining all
outcomes and a fixed signed 6472-minus-4205 margin. This maps two policy factors
and their interaction, not the entire GPU arithmetic gap. It does not select
an app profile, replace an oracle or provide production/phone clearance.

The four-arm study is now complete. Each arm ran in its own GPU-only process,
using the same canonical two-row decode. The unchanged baseline reproduced all
18 native and four restored legacy comparisons exactly. All eight required
cross-prefill restored tensor pairs are bit-identical. The analyzer pins the
historical report, certified diagnostic and preregistration, checks exact
condition/lane membership and verifies raw tensor hashes. Seven Python control
tests and all 21 Release regression tests pass.

| Prefill | RoPE | Old oracle passes | Certified CPU diagnostic passes | Native target signed margin |
| --- | --- | ---: | ---: | ---: |
| Native quantized | Native GPU | 20/22 | 21/22 | +0.000084877014 |
| Canonical half, dense FP32 accumulation | Native GPU | 20/22 | 21/22 | +0.000020980835 |
| Native quantized | Pinned CPU half table | 19/22 | 22/22 | -0.000391006470 |
| Canonical half, dense FP32 accumulation | Pinned CPU half table | 19/22 | 22/22 | -0.000354766846 |

Thus, in this fixed study, changing RoPE is sufficient to align the remaining
target ranking with the certified CPU diagnostic under either prefill policy.
Changing prefill alone is insufficient. Agreement with this diagnostic is not
an independently qualified model reference or permission to replace the old
acceptance gate. The old oracle continues to reject the three target conditions
for both half-RoPE arms. Raw results and both reference comparisons remain intact.

Measured MLX peak allocations were approximately 1.05/1.96/0.95/1.78 GB in table
order. These are offline Mac allocations, not iPhone process footprint, narration
throughput or battery results. No production loader default, decoder profile,
renderer oracle or phone state changed. Evidence is in
`runs/chatterbox-quantization-evaluation-v01/gpu-policy-factor-study-v01/controls-report.json`.

The subsequent independent scalar RoPE audit found 16/32 frequency bits differ
from backend-generated CPU frequencies. Across all 1,536 positions, this changes
1,792 position/frequency pairs of half trig values. Holding imported frequencies
fixed leaves one CPU trig discrepancy: position494/frequency7 cosine is48048,
where the independent calculation gives48049. All policies agree at position95,
so that captured rotation cannot distinguish their behavior at later positions.

The independently defined table has now been qualified without the preliminary
assumed transcendental enclosure. Each power-frequency decision uses exact
rational binary32 midpoint powers. Machin and trig Taylor calculations use
directed Decimal120 arithmetic with explicit alternating/Taylor remainder
bounds. All32 frequency,49,152 phase,98,304 trig and98,304 half-conversion
certificates pass. Twelve Python tests pass normally and with optimization,
including rational interval checks and rounding/identity failure cases. Existing
Astra review independently verified table size/hash and exact candidate bits.

The resulting diagnostic table is196,736bytes (32frequency words, then cosine
and sine half arrays), SHA-256
`1d58a8abbe8e7f9c668cbc3d3b53bee8563e43f7cdb4cb8b758100f7ec664ca9`.
It is not installed or selected by a renderer. Source and report are preserved
under `semantic-rope-certificate-source-v01` and `semantic-rope-certificate-v01`.
This closes this table's numerical definition, not the remaining operator or
whole-model qualification. The next finite steps are independent same-input
operator checks using existing captures, then unseen valid public EN/ES prefixes
crossing cache256 and actually evaluating494 or later, before any app profile.

The preregistered remaining-operator audit is complete on the existing captured
inputs, with no model forward. Exact binary32 integer reductions and root-midpoint
comparisons implement the declared boundaries. Sigmoid/softmax use directed
intervals enclosing the [correctly rounded Decimal exponential](https://docs.python.org/3/library/decimal.html#decimal.Decimal.exp).
The full pinned weight file is hashed while streaming; norm/head rows are read
without retaining the packed artifact. All60 residual additions (122,880values)
are bit-identical, and every captured activation-to-half cast association passes.

| Operator | Values | Different F32 bits | Different half-cast bits | Maximum absolute error |
| --- | ---: | ---: | ---: | ---: |
|61 RMS norms|124,928|52,296|10|0.00000190735|
|30 SiLU/up products|245,760|82,525|15|0.000000238419|
|30 attention outputs|61,440|51,054|44|0.000000238419|
|60 residual additions|122,880|0|0|0|
|Final F32 head|16,388|15,325|19|0.0000247955|

The head's existing comparison criteria pass with relativeL2 approximately
0.000000640834 and both leaders unchanged (5986/6472). Its half-cast column is
diagnostic only; the accurate model's head stays F32. Large ULP counts near zero
do not imply large absolute errors. All independent bits, attention scores and
probabilities are retained with the182 comparisons. Eight tests pass normally
and with Python optimization; the three injected cancellation cases cover
publication boundaries, not interrupted numerical loops. Runtime was37.88seconds.

This qualifies same-input operator behavior under the frozen strict array
sequence; it does not qualify an assembled independent model or choose a new
oracle. Source/outputs are in `semantic-operator-source-v01` and
`semantic-operator-audit-v01`. The next stage must assemble these declared
operations and preregister valid public EN/ES inputs before evaluating the
candidate. Keep the old profiles/references rejected and unchanged.

The nonlinear reference buildingblock now avoids scalar Decimal work for every
probability. Its optimized CPU interval polynomial evaluates P24(x/256), uses
the explicit Taylor remainder below2^-83 on[-1,0], then performs eight interval
squarings. Coefficients and operations round outward. Error-free TwoSum retains
score-difference residuals; small exponential mass stays bounded rather than
being dropped. A row that spans any F32 rounding boundary returns no approximate
probabilities and requires the independent Decimal resolver.

All960 captured rows (92,160probabilities) certified directly and matched the
scalar reference bit-for-bit; no captured row needed fallback. The known
`[0,2^-23]` midpoint case deliberately remains unresolved in Release and its
Decimal resolver produces the exact expected bits. An exhaustive finite-F16
sigmoid cache contains63,488 qualified values and2,048 forbidden nonfinite
sentinels. Its262,144byte table hash is
`71da0d3bb8b7812e046eb6128e7538b13903c2ad0a68a6bb3c789e97aa176b7e`.
Lookup-based evaluation reproduces all245,760 captured SiLU/up outputs exactly.

All24 Release regressions passed; three focused Release tests include exact
TwoSum residual-sign endpoints, and three Python tests pass normally and with
optimization. This qualifies nonlinear engine components only. Generic certified
GEMM/norm/head work must still reproduce all182 scalar outputs before assembly,
original/eager controls and the frozen six-case holdout. Nothing selects this
component or its tables in a production renderer. Evidence is preserved under
`reference-softmax-fastpath-v01`, `reference-nonlinear-component-v01` and
`reference-nonlinear-source-v01`.

The remaining CPU reference engine now reproduces all182 scalar operator
outputs **bit-identically**, as well as all60 auxiliary score/probability tensors.
It uses CPU64 GEMM with outward-rounded general magnitude/error bounds, exact
normalized dyadic Int128 fallback with preflight span/overflow checks, and a
bounded bigint resolver for wider spans. RMSNorm retains the specified square,
exact mean, epsilon, squared-midpoint inverse-root and multiplication boundaries.
Neither the old half-only helper nor any production gate was widened.

The validation recorded169,615 certified outputs,495 Int128 resolutions and one
deliberately overwide bigint control. The actual GEMM fallback transports
`[maxF32,-maxF32,minSubnormalF32] dot [1,1,1]` and returns the exact minimum
subnormal. A separate actual subprocess resolves the known softmax midpoint row.
Both request/response UUID/hash/shape controls pass. All runtime helper and import
files are pinned; unresolved calculations never use native arithmetic fallback.

All31 Release tests passed without skipping, including F16-output GEMM at
K96/1024/1536/4096 against the prior exact integer helper and real Swift-task
cancellation of owned Python workers, both ordinary termination and deliberate
SIGTERM refusal. Cleanup permits one second for TERM, then one second for an
owned-child KILL/join, and throws if termination is not observed. Three Python
tests pass normally and with optimization, including partial-failure and shared
deadline rejection. The engine operator bits have SHA-256
`540f13b4e357fe7d1ed873767bd3539ac92dbaf43453625c7004ebc319733b3a`.

This completes engine-to-scalar operator equivalence, not whole-backbone or
phone acceptance. Next are reviewed independent assembly, original/eager-native
boundary controls and the already preregistered six public input trajectories.
No app oracle/profile, source recordings or phone state changed. Evidence is in
`reference-vector-engine-v01` and `reference-vector-engine-source-v01`.

The six public EN/ES holdout inputs are now frozen, with no decoder forward or
audio generation. The canonical local stock frontend produced 18 tensors:
prefix embeddings, eight teacher-forcing inputs and text IDs per case. All21
frontend files are pinned, including stock conditioning; the three optional
tokenizer configuration/template files are required absent before and after
preparation. The manifest itself is size-bounded and hash-pinned before decoding.
The source was independently reviewed and33 Release regressions passed.

| Case | Prefix rows | Planned decode offsets |
| --- | ---: | --- |
| English short | 80 | 80–87 |
| English boundary | 251 | 251–258 |
| English long | 501 | 501–508 |
| Spanish short | 87 | 87–94 |
| Spanish boundary | 252 | 252–259 |
| Spanish long | 503 | 503–510 |

The fixed teacher-forcing IDs remain `[173,920,31,404,2100,781,64,1500]` at
speech positions1–8. Selection used whole-word token counts only: last valid
boundary prefix, first valid long prefix. No model score influenced selection.
Vector SHA-256 is
`2d20b5932df08b022cbd95e5713de5f5f1c0b15fcebde04801f42b6a0584baf7`.
Evidence is in `assembled-holdout-frozen-inputs-v01` and
`assembled-holdout-preparation-source-v01`. The preparation report's
`maximum_evaluated_position` field denotes a **planned** position only:
`decoder_forward_count` is zero. Actual256-boundary and494+ position evaluation,
full/chunk cache identity, all54 comparisons and phone clearance remain pending.
