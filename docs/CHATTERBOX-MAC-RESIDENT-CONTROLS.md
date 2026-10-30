# Resident full-quality Mac GPU controls

M3 Ultra, 256 GiB; one resident Standard decoder and full-F32 native acoustic
model. Ten cosine steps, CFG .7, stock conditioning, fixed request seed,
watermark disabled. Startup is separate; the product timer includes planning,
decoding, acoustics, cadence, audio cache, ALAC24 encode and decoded verification.

## V02 result

| Policy | English audio / warm wall | Playback multiple | Spanish audio / warm wall | Playback multiple |
|---|---|---:|---|---:|
| Sentences, serial | 13.32 / 7.0273 s | 1.895x | 16.48 / 7.6436 s | 2.156x |
| Sentences, overlap | 13.32 / 6.3381 s | 2.102x | 16.48 / 7.6060 s | 2.167x |
| Grouped, serial | 12.40 / 5.0355 s | 2.463x | 14.20 / 5.7653 s | 2.463x |
| Grouped, overlap | 12.40 / 4.9680 s | 2.496x | 14.20 / 5.7399 s | 2.474x |
| Sentences, repeat | 13.32 / 6.6614 s | 2.000x | 16.48 / 7.8567 s | 2.098x |

Grouping changes prosodic context and audio duration. It is not the same waveform
as sentences. Within each grouping, serial/overlap PCM is bit-identical in both
languages; serial/repeat is also identical. All source ranges cover the frozen
original text. These short cases are not whole-chapter, concurrency or cloud
measurements. Listening approval and the 5x goal remain open. Cold validation and
loading was 143.0048 s; it is not the optimization target for the resident worker.

## Separate waveform policy

V01 retained all outputs but failed its strict same-waveform gate. Saved cache
analysis found tiny F32 differences in serial repeats as well as overlap. The
legacy ISTFT uses colliding atomic scatter-adds. The separately versioned
`deterministic-gather-2` policy sums the same frame/window contributions in a
fixed ascending frame order. Learned weights, FFT, window, trim and clipping are
unchanged. Legacy default and cache identity remain unchanged; the new policy
has its own cache identity and must be selected explicitly.

Synthetic CPU scalar parity and bounded GPU scalar fidelity/repeat gates passed
before V02. V02 passed the original strict full-model PCM identity requirements;
no tolerance or decoder/oracle gate was widened. This supports the correction
for these controls, not universal model determinism or listening equivalence.

## Evidence

Owned SSD run `runs/chatterbox-macos-pro-evaluation-v01/resident-gpu-controls-v02`:
manifest SHA256 `4f1a443ccb682c6f556f8e8fd09dfb72b3c7862490bb709a9c8772d74e8c9715`,
report SHA256 `bd7518611030939e3079c70b3cd91102c5bf58a298079708aa28b48cee76ef4c`.
Independent review verified 152 source bindings, runtime/frontend/binary/config,
all ten ALAC hashes, six raw-PCM pair controls and source maps. All owned model
processes joined; no automatic restart. Failed V01 remains preserved.

Codec comparisons are separately documented in CHAPTER-AUDIO-DELIVERY.md. The
old baseline exported both WAV and ALAC; V02 exports the selected ALAC only.
Do not attribute the timing difference solely to the waveform implementation.
