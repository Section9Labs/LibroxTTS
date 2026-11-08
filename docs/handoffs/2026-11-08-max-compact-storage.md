# Max checkpoint-exact compact storage experiment

This is an opt-in test-only experiment in `PocketCompactStorageExperiment.swift`,
not enabled by the SDK renderer and not shipped to the app. It builds on the
resource-recovery candidate at beta.5 base 8e4645b.

Plus already uses bounded vocoder windows (`CTVocoderWindows.swift`) to preserve
context without retaining a whole-passage decoder activation graph. Max already
emits 80ms codec frames, so copying that mechanism alone would not deliver the
same saving. A large remaining target is resident transformer weights.

The hosted checkpoint uses BF16. The loader's sanitization expands weights to
FP32. The experiment stores ONLY the flow transformer Linear weights as BF16,
checks exact round-trip equality for every converted weight, expands them to FP32
for each operation, and evaluates at attention/feed-forward boundaries. It does
not quantize the checkpoint further or alter FP32 arithmetic, voice, eight steps,
temperature (0.3), seed (42), or text. Norms/flow network/decoder are unchanged.

## Measured on this Mac, Release, one English passage

| Backend | Storage | Resident MLX bytes | Render peak MLX bytes | Render seconds |
| --- | --- | ---: | ---: | ---: |
| GPU | Existing | 398901904 | 509931504 | 0.724612 |
| GPU | Compact | 247906988 | 358905542 | 0.945664 |
| CPU | Existing | 398903184 | 454488488 | 6.593994 |
| CPU | Compact | 247907984 | 303507436 | 8.068371 |

Both backends returned 109440 samples (4.56 seconds at 24kHz) and maximum PCM
absolute difference of exactly zero against their respective baselines. These
are single trials, not throughput distributions or listening qualification.
The measured saving is about 38% resident MLX, 30% GPU render peak, 33% CPU render
peak. Rendering was about 31% slower on GPU and 22% slower on CPU. The initial
per-linear barrier variant was 57% slower on GPU; block boundaries reduced that
overhead with the same PCM result.

Memory is MLX allocations, NOT total process RSS/footprint. Peak counters were
reset after model loading/storage conversion. This experiment therefore does not
claim improved cold-load peak: it first loads the expanded model and then replaces
the weights. A production loader would need to retain original checkpoint storage
from the start and separately validate load-time peaks.

An initial attempt to replace every Linear hit an unsupported mutable module
structure in the flow network's adaLN array. The experiment was restricted to the
transformer, which accounts for 150994944 bytes of exact weight-storage savings.
No production runtime path was changed to work around that experiment failure.

Before promotion: directly load compact weights, test multilingual/numerical and
listening comparisons, sustained CPU/GPU throughput and thermal behavior, memory
pressure/cancellation/backend changes, and actual iPhone foreground/background.
Slower CPU generation can worsen buffering, so no automatic production switch is
justified by these Mac measurements alone.

Evidence: `/Users/matt/Code/swift/Libros/.git/librox-release/evidence/max-sdk-resource-2026-11-08/compact-storage-comparison.json`
and the three `max-compact-storage-*.log` files in that directory.

Further rejected variants: asynchronous block evaluation increased GPU peak to
563 MB and took 1.214 seconds versus 0.769 seconds. Feed-forward-only storage
saved 101 MB but still took 0.863 seconds versus 0.690 seconds. Neither was
promoted. The production beta.6 approach instead reduces cold-load overlap and
retired streaming state while retaining expanded FP32 weights for rendering speed.
