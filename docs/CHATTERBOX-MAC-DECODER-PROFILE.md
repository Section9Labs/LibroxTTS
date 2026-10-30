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
