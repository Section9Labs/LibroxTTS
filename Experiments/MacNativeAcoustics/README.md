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
