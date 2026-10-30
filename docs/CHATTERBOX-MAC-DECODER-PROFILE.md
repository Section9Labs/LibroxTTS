# Resident Mac decoder profiling

The complete audio target remains RTF <= 0.20 (five seconds of playback per second of work). Startup is reported separately because the Mac worker keeps its models loaded. Decoder-only throughput does not establish whole-chapter speed.

## Fixed public EN/ES profile

`native-decode-stage-profile-v01` completed four profile-off/on arms using fresh KV caches and unchanged public Standard inputs. Off/on token sequences were identical (117 EN and 152 ES). No acoustic model, exported audio, audio cache or cloud operation participated. The diagnostic sink is never a production renderer.

| Instrumented arm | Complete decoder wall | Model evaluation | Graph construction | Sampling | Logit readback/CFG |
| --- | ---: | ---: | ---: | ---: | ---: |
| EN | 0.964 s | 0.796 s | 0.0848 s | 0.0674 s | 0.00624 s |
| ES | 1.320 s | 1.100 s | 0.1115 s | 0.0884 s | 0.00829 s |

Evaluation accounts for approximately 83% of accounted work; graph construction about 9% and sampling about 7%. These are synchronous host boundaries around MLX graph construction/evaluation, not measurements of isolated GPU kernels. Instrumented/uninstrumented wall differences are not an optimization claim. The profile report SHA is `29c6422f4ba4976ea8b84ef9945cba12f0bba2c51c9ce44038f527a49a80d122`.

The actual expressive book run is much slower than an isolated short decode. Its 32.56 seconds of playback took 26.325 seconds of complete warm work, including AAC export/readback (1.237x playback). Decoder and acoustic stage totals overlap and must not be added to infer wall time.

## Bounded allocation/scheduling control

`book-resident-scheduling-v01` tests serial versus overlap with the existing trimming policy and an explicit bounded resident Mac policy. The implementation changes allocation lifetime only: no learned weights, dtype, arithmetic, sampling, expression controls, solver steps or output guards change.

Each arm starts after clearing unused allocator buffers outside its product timer. Models remain loaded; every arm has a fresh audio cache. Resident arms retain unused buffers within that arm under the configured 256 MiB MLX retention limit. That setting is not an instantaneous cached-byte ceiling: MLX reclaims excess on subsequent allocation. The supervisor retains the independent 6 GiB process RSS limit and thermal/memory/cancellation guards.

The six ordered arms are warmup, legacy serial, legacy overlap, resident serial, resident overlap and legacy serial repeat. Every arm must match the approved expressive book's actual raw PCM SHA `1c5b3ec4f710daa927aef8597453a2952dd6802d316f7d3ff9c0653edcf60ece` and all source/unit/token/frame/scalar descriptors. Each observed receipt is retained before validation; a mismatch stops before the next arm. No performance result is accepted without this quality control.

Exact-shape first-use warmup and a single book paragraph cannot establish sustained chapter throughput. Scheduling differences include allocator and runtime-lock effects; they do not by themselves identify hardware contention. The original default trimming policy remains unchanged until the measured evidence supports a separate host selection.

### Completed same-book result

All six arms matched the exact approved PCM and descriptors. The supervisor joined the child and confirmed it absent. Report SHA `0706011d9c3662b894bc9bb6f44d6921dad6d57fa174c3fe7e2865c345261e8b`.

| Arm | Complete warm work | Playback/work |
| --- | ---: | ---: |
| First-use serial warmup | 11.551 s | 2.819x |
| Existing trimming, serial | 11.013 s | 2.957x |
| Existing trimming, overlap | 11.937 s | 2.728x |
| Bounded retention, serial | 10.935 s | 2.978x |
| Bounded retention, overlap | 11.214 s | 2.904x |
| Existing trimming, serial repeat | 10.918 s | 2.982x |

The baseline repeat is as fast as bounded retention; retention has no convincing additional benefit in this control and is not selected for production. Serial is the Mac book scheduling baseline from this evidence; overlap remains explicit rather than being assumed faster. Decoder work was approximately 7.1 seconds versus 3.4 seconds of acoustics in serial. The full 32.56 seconds of audio still takes approximately 10.9 seconds to produce and verify as AAC: the 5x target requires 6.512 seconds or less. Cold validation/loading took 141.791 seconds separately.

These runs qualify exact waveform preservation for the scheduling/allocation policies on this passage. They do not establish a speedup over the older separately timed audition under identical host conditions, unseen-input sustained chapter performance, concurrent workers, iCloud transfer or battery behavior.

### Cache-parent hypothesis rejected

The tiny CPU/GPU cache-boundary diagnostic completed in `dense-cache-parent-availability-v03` (report SHA `973f32384f3f39a282941480c1d8ead2424294c4bd0fab6efca7514eb26e3e55`). At offsets255,256,257, both retained cache parents changed from unavailable to available after evaluating only their attention consumer. The repeated-query unexecuted-exp control remained unavailable until explicitly evaluated. This agrees with the reviewed MLX dependency traversal and gives no support for a deferred full-cache replay fix. No joint-cache evaluation change is selected; no model weights or audio participated. The internal availability query can detach completed events but schedules no new work.

The two earlier launcher failures are preserved: v01 tried to execute a Mach-O XCTest bundle directly, and v02 rejected a stale version literal before subprocess creation. Neither started the diagnostic. V03 uses the already-built SwiftPM test runner under an owned60-second process-group watchdog. The test itself applies a10-second work budget, bounded runtime reads, memory/thermal/cancellation checks, and writes observations before rejecting unexpected results. Default tests skip this opt-in diagnostic.

## Default-off compiled decode MLP trial

`compiled-decode-mlp-1` compiles only the accurate decode MLP path at sequence length1. Prefill, attention, norm, RoPE, KV storage, sampling and acoustics remain unchanged. Explicit F16 projections/F32 activation and product/F16 down-input/output casts remain in source. Compiler fusion can still change rounding, so this is a separately identified numerical candidate, not an automatic equivalence claim.

A fresh-GPU tiny qualification verified exact eager/compiled output bits before and after live parameter updates, changed output after the update, and release of both owner and captured child modules. Report SHA `3d2af681afa287646356f82a316c8af94d0f2d7b95bb9faae01762fe09f9f7af`. Default tests skip this workload. Nine normal Release tests pass (eight existing XCTest plus one execution/cache-identity test).

The full `compiled-decode-mlp-book-v01` then passed the original18 startup checks and all six exact expressive-book PCM/descriptor controls. Report SHA `95e57f9dd29b75770c84c22fd4334b26aefe1a35d1274b13a6da99705f12ab5d`; owned child joined. Serial11.013–10.918 seconds in the earlier eager study versus compiled serial13.382–13.292 seconds in this run is NOT a matched same-host causal comparison. Unchanged acoustic timings also rose (approximately3.4 to4.2 seconds), so the slower wall time cannot be assigned entirely to compilation. There is no demonstrated speed win and the candidate remains off. The complete compiled run reached approximately2.43–2.47x playback, not5x. Full fixture qualification including first tracing took0.534 seconds, within141.418 seconds of cold loading/validation; this is not compilation time alone.

Before reconsidering this candidate, use a preregistered interleaved eager/compiled control on the same resident model pair. Preserve every old gate/reference and exact audio controls. Do not repeat the completed separate-run study or promote a candidate because it merely passes correctness. EN book fidelity does not establish a new complete Spanish/chapter/cloud qualification.
