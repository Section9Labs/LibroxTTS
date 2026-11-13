# Execution decisions and limits

The unchanged 0.9 Core ML profile for the fixed Caro/Calm four-step passage spent
about 57% in latent-transformer predictions, 23% in the codec, 16% in flow, and 2%
in text prefill. Those timers include each stage's host bridge. Even eliminating
all time outside these stages cannot produce 2x synthesis throughput.

The candidate removes native voice-state preparation's MLX conversion and keeps
flow latents in Core ML arrays through their next transformer/codec uses. It does
not change RNG. Pinned MLX 0.32.3 `random.cpp` implements normal sampling through
uniform generation, an inverse error function, dtype conversion and multiplication.
Replacing that pipeline requires matching both the key stream and floating-point
implementation. The unaccounted warm time bounds its possible end-to-end payoff;
duplicating a numerical runtime for that residual is not justified. Core ML still
links MLX and no lean-binary claim or new product is made.

Stateful Core ML would require new model representations and compiled receipts.
The current contract pins complete model-pack bytes, source identities and receipts.
No representation swap is admitted into this drop-in candidate. A pinned-runtime flow-compilation experiment is recorded in
`flow-compilation-experiment.json`: all 16 CPU/GPU probes preserved all 32 output
values bit for bit. This does not establish complete-engine PCM parity. First CPU
execution spent 156.3 seconds compiling; first GPU execution took 2.10 seconds on
the shared Mac. Warm isolated flow timings were lower, but the startup cost,
platform constraints and missing full-engine gate rule out default admission.
No numerical tolerance, global compilation switch or dependency upgrade is used.

The private MLX capacity experiment is evaluated independently of public cache
semantics. Public constructors keep their reference behavior. Exact audio alone
is not grounds for keeping capacity storage if paired runs show slower inference
or more memory. Private rotary-term reuse shares identical pure expressions across
layers, scoped by time, dimension, position, period and device; direct public model
construction retains the legacy path.

Only immutable text assets are pooled across Core ML owners. Mutable model instances,
MLXArray weights exposed through public models, RNG and decoder state are not pooled.
This avoids making undocumented immutability assumptions or hiding source changes.
Source bytes are read and hashed at every acquisition, and weak leases release the
last owner's resources. Files are still fully verified on every load. Parallel
hashing changes the schedule of reads, not the files, checksums, size policies or
ordered error selection; it waits for its bounded workers before returning.

## Final admission decisions

Capacity storage is excluded. The three-variant ABCCBA receipt in
`backend-abba.json` compares 0.9, rotary-only production, and rotary plus capacity.
Removing capacity was roughly 4–6% faster for warmed CPU cases while using about
5–13% more sampled footprint. GPU medians favored capacity by about 5–12% in time
and 5–6% in footprint, but the two rotary-only GPU process totals ranged from
68.5 to 92.3 seconds on the shared host. This does not establish a consistent
cross-backend benefit; the patch and exact-audio experiment remain reproducible.

Rotary reuse is admitted. The final isolated six-layer, 64-position ABBA test in
`rotary-ablation.json` reduced component time by 24.3% on CPU and 22.0% on GPU.
The component bit test covers position/shape/device changes; the whole-engine
78-recording matrix covers actual output. These component gains are not a claim
of equivalent end-to-end speedup. Whole-engine timing is in `backend-abba.json`.

The final Core ML native-voice integrity guard was added after that three-variant
receipt. `backend-coreml-final.json` and `profile-abba.json` measure the guarded
production code; the guard does not affect MLX. `audio-matrix.json` and the final
device run also use the guarded code.
