# Native Swift acoustic inventory

Offline strict metadata stage only. It instantiates the pinned, acoustic-only
regular Swift S3Gen constructor on CPU and accounts for all 2487 tensors of the
verified full-quality checkpoint. It does not load weight payloads into a model,
call a forward, generate audio, use private conditioning or launch a GPU model.

The standalone executable requires the known model SHA and guards thermal,
low-power, cancellation, 3 GiB RSS and 180 seconds. Its external supervisor adds a
hard deadline/RSS watchdog and bounded TERM/KILL join. No automatic restart. The constructor evaluates its fixed CPU normal-noise array
once; zero model forwards does not mean zero array evaluations.
Preserve a rejected report; no unknown/missing/shape-mismatched tensor is waived.
A matching inventory is not loading or numerical/quality/speed clearance.

Freeze the reviewed source, executable and manifest in a fresh owned run folder
before invoking the supervisor. The manifest must enumerate source hashes,
checkpoint path/hash, exact binary, meanflow:false, zero forwards allowed, a
180-second deadline, 2-second cleanup budget and 3 GiB RSS cap. The output report
is published atomically; the supervisor result is last, after the child joins and
source/binary identities are rechecked. No downloads or dependencies during runs.

Next stages are separately reviewed strict loading of every learned tensor,
explicit constructor-state parity, then a fixed valid token/stock-conditioning
trajectory with ten cosine/CFG steps and .7 guidance. Never use random constructor
weights, permissive loading, peak normalization or partial cancellation output.

The v01 run is terminal: spawned `ps` watchdog queries timed out under load; its
Swift child exited on TERM, and later independent verification found its process
group absent. No inventory/model forward completed, and its failure remains.
The separately reviewed v02 uses direct Darwin libproc/Mach resource queries and
per-read autorelease pools during checkpoint hashing. Bounds remain 180 seconds,
3 GiB RSS, 4 GiB available memory, 2 GiB storage and thermal/low-power stops. No
external resource-query subprocesses are spawned. v01 is never restarted.

The v02 child is terminal: its relocated executable could not find MLX's shared
`default.metallib` during CPU-stream bootstrap. It exited255, its owned group
joined, and no inventory/forward completed. Its observed identity-pass RSS was
18.7MB; this is not resident model memory or a rendering benchmark.

The separately versioned v03 copies and pins the shared MLX0.32.3 runtime library
(size2401016, SHA282550b064507602f7da8cfa2dab2ca8f10341c2802191234a1cbf17f892952f),
sets the documented metallib path before the first MLX operation, and retains
path/descriptor/hash checks before and after CPU construction. MLX bootstrap can
initialize the Metal runtime; no GPU model forward is permitted. This is a runtime
dependency correction, not revival of an old CoreML GPU/ANE failure. No v02 retry.

The v03 runtime bootstrapped correctly and the strict constructor gate rejected
381 mismatches, preserved in its report: 190 missing/190 unexpected encoder-array
names and one unsupported regular-mode Turbo mixer. The v04 correction maps only
those anchored encoder prefixes and physically omits the unused mixer in regular
mode. All1367 learned shapes/types match uniquely against the actual preserved
v03 capture in a regression test. A fresh v04 constructor gate is still required;
this regression does not waive any runtime parameter or qualify audio. The global
RNG draw-count side effect of omitting an unused constructor is documented in
PROVENANCE; future rendering must freeze independent request/vocoder noise.
