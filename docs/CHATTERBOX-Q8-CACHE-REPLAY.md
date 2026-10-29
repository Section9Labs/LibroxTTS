# Fixed-fixture cache intervention

V2 still fails the phone's `es.decode.2` ranking check before audio. Its error
bounds pass; the reference's unconditional top-two margin is only .000247955.
Do not change the reference, tolerances, ranking requirement or production gate.

`ChatterboxQ8FixedFixtureDiagnostic.run(configuration)` is a separate, non-audio
measurement API. It accepts only three file URLs: the existing pinned Q8 weights,
the existing pinned Q8 oracle, and a new pinned CPU prefill-cache fixture. It never
returns a renderer, accepts narration text/conditioning, or clears inference.

The cache fixture is
`cpu-es-prefill-kv-v01.safetensors`,22,862,030bytes,
SHA256`59e0cbdab848feb2977359ac8a8e90e0bd0dc54a0fafa312f86fd5f7c7d01f6f`.
It contains60FP16 arrays `[2,16,93,64]` (22,855,680payload bytes). The exporter
reproduced all18frozen CPU outputs bit-for-bit and copied independent host bytes
immediately after prefill. No recording, book text or private conditioning is
included. Its receipt and exact exporter source are in
`runs/chatterbox-quantization-evaluation-v01/prefill-cache-reference-v01` on T9.

The diagnostic runs three sequential arms using the same V2 decoder:

1. Native prefill caches, followed by three fixed Spanish decode inputs.
2. Native caches snapshotted and restored through zero-padded256capacity buffers,
   preserving offset93 and strides, then the same three decode inputs.
3. CPU-reference prefill caches restored identically, then those decode inputs.

Each arm first performs the normal preceding English fixture work. All reported
prefill logits remain native; substitution affects decode only. Reports include
both lanes' expected/actual leaders, signed margins, unchanged gate results and
full-logit bit agreement between the first two arms. A failed native-restore
control makes the intervention inconclusive. CPU-restored success only shows
that changing inherited state recovers this sequence; it does not identify a
specific prefill operation or prove the decoder exact.

The Mac control completed in1.89seconds with native restoration bit-identical at
all three decode steps. Native passes; CPU-restored fails the near-tied step.
That result illustrates why another prefill correction cannot be selected from
Mac success alone. Physical phone results are still required.

The caller must stop, cancel/join and unload narration, retain the existing64MiB
MLX buffer pool, keep GPU eligibility in the foreground, and prevent narration
from restarting until the diagnostic joins. The SDK rejects concurrent diagnostic
runs, propagates cancellation, joins its worker, and retains all resource guards.
Reports are fixed-fixture measurements only; `peakBytes` is process-global
historical MLX peak. Preserve the original production load failure regardless
of the diagnostic outcome. An isolated diagnostic app avoids adding this path
to customer narration while the numerical cause is under investigation.
