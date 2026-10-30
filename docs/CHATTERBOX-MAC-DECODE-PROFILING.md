# Native MLX decoder profiling

`CHATTERBOX_PROFILE_DECODE=1` now enables numeric aggregate stages in the native
MLX renderer, using the same existing opt-in flag as the Core ML adapter.
`ChatterboxChunkTimings.decodeSteps` carries the results, and the Mac probe's
per-passage receipt retains them. The default remains nil, with no clock calls
inside the normal decode loop. No request text, voice data, logits or per-token
logs are added to timing metadata.

Native boundaries:
- inputPreparationSeconds: initial cache/input/sampler setup and subsequent
  speech-embedding/input-array preparation;
- predictionSeconds: decoder graph construction plus the unchanged eval(logits);
- logitsCopyAndCFGSeconds: the unchanged asArray readback plus finite-output
  checks and CPU CFG combination;
- samplingSeconds: unchanged seeded sampler;
- resourceGuardSeconds: timing around the already-existing per-step guard,
  including cancellation and memory/thermal/low-power checks.

This is host stage accounting, not pure GPU kernel measurement. Deferred
synchronization is charged where it occurs. Native totals include prefill and
EOS iterations; Core ML's existing loop counts autoregressive decode only.
The legacy serialized four-stage schema decodes with a nil resource field and
its accounted sum remains unchanged. No extra model evaluation, sampler call,
resource check, dtype/precision/cache policy or solver operation is introduced.
All GPU tensors remain inside the synchronous decode scope.

## Required next bounded experiment

Before selecting a sampler or kernel optimization, use one fresh owned
GPU process with verified Standard weights/oracle/frontend and two frozen
public EN/ES inputs. No recordings, acoustics, audio files or cloud operations.
Use an explicitly named diagnostic acoustic stub only to return numeric decoder
metrics through the existing seam; dummy samples must never be exported/cached
or described as generated audio. Keep seed/scalars/min/max-token policy fixed.
Require complete token identities between profiling-disabled and enabled arms,
fresh per-request KV caches and unchanged oracle/resource guards. A failed token
control invalidates performance interpretation. Measure stage contributions and
unaccounted wall overhead; do not claim end-to-end throughput from this test.
Freeze inputs/source/binary/config first; bounded owned supervisor, memory,
thermal, low-power, cancellation and joined-exit receipt required before launch.
No diagnostic model run has been performed for this instrumentation stage.

The motivating real-book sample measured23.307s prefill+decode and11.908s
acoustics overlapped within26.325s warm work. Those totals alone do not identify
whether sampling, resource checks, graph dispatch, execution or readback is the
hotspot. Completed audio auditions remain immutable and are not rerendered by
this stage.
