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
