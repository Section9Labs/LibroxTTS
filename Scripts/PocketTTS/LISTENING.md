# Narrator listening suite

Generate native audio for structured listening review. No preferred voice or
configuration is selected automatically. The passages are original test prose.

```sh
swift build -c release --product pocket-tts-probe
python3 Scripts/PocketTTS/listening_suite.py \
  --probe .build/release/pocket-tts-probe \
  --assets /path/to/pocket-packs \
  --output /path/to/listening-suite
# Optional ASR screen, in the existing mlx_whisper environment:
python Scripts/PocketTTS/screen_listening_suite.py /path/to/listening-suite
python3 -m http.server 8791 --bind 127.0.0.1 --directory /path/to/listening-suite
```

Open `http://127.0.0.1:8791` or the generated `index.html`. The page has no remote
scripts or resources. Keep its `audio` folder beside it. Ratings and notes stay in
browser storage; export reviews to JSON to preserve/share them. The export includes
full configurations and audio identities. Nothing is submitted to a service.

## Comparisons

The v2 suite starts at **four sampler steps** for all voice, temperature, phrasing
and repeat-take auditions. It adds an eight-step quality audition and hides one-
and two-step performance fallbacks until the reviewer enables them. The initial
one-step v1 suite is preserved in its original output directory, with its reviews.
Use a new `--output` directory for v2 (for example `listening-suite-quality`).

No automatic downgrade is selected. Reduce computation only after measuring a
constraint on the actual target device; test-Mac timing is not phone qualification.

- **Voices:** six English and four Spanish candidates; three passages each. Alba,
  Jane, Vera, George, Peter Yearsley and Stuart Bell in English; Lola, Alba, Jane and
  George in Spanish. Cross-language voices are audition candidates, not accent endorsements.
- **Temperature:** 0.15, 0.30, 0.45; other parameters fixed.
- **Phrasing:** short (24/16 narration/dialogue targets, no short-sentence extension),
  balanced (48/32, short threshold 12), flow (72/48, short threshold 12). All use a
  96-token hard cap, whole-sentence preservation and a 2,400-scalar outer bound.
- **Compute headroom:** four-step baseline, eight-step quality audition; two and
  one are optional device-performance fallback comparisons. Other parameters fixed.
- **Repeat takes:** seeds 42 and 77 on the reflective passage at baseline settings.

Temperature, phrasing and sampler sweeps use Alba/George in English and Lola/Alba
in Spanish as comparison anchors. They are not predetermined winners. Every round
reuses the same source passages. Quoted dialogue is read by one narrator in this
suite; multi-character casting is a separate evaluation.

Generation is resumable only when the exact request, probe binary and stored WAV
hash agree. All main comparisons use seed 42. The probe loads weights before seeding
and runs one engine per process, so the SDK never resets another caller's global
RNG. Equal seeds do not mean noise stays aligned after changing chunk boundaries.
Run repeat takes before assuming a single good clip represents a configuration.

The direct engine accepts bounded `samplerSteps` (1–8), defaulting to **four** on
every call. The shared narration renderer also defaults to four. A Codable
`PocketTTSSamplingOptions` travels through `NarrationPipeline`, each unit and its
render cache identity. Explicit lower-step settings must be deliberate host
choices based on target-device measurements. Generation errors never trigger a
silent lower-quality retry. The review page shows generation time relative to
audio duration on the M3 Ultra test Mac; model load is excluded from generation
time and retained separately as `processSeconds` in the manifest.

The page exposes actual chunk decisions, render duration, full settings and optional
ASR discrepancies. ASR is a content screen, not a narration-quality score; listen
to establish whether a flagged word is wrong or the recognizer made a mistake.
The audio has no loudness normalization, compression, pitch or speed adjustment.
The first pass selects a voice; the later passes tune it. Follow up on the preferred
combinations with long chapters and the target device before shipping a preset.

## Compute measurements

After generation, ASR and builds/tests finish, run the separate sampler benchmark
without overlapping agent GPU jobs:

```sh
python3 Scripts/PocketTTS/benchmark_sampling.py \
  --suite /path/to/listening-suite-quality \
  --probe .build/release/pocket-tts-probe \
  --output /path/to/listening-suite-quality/compute-benchmark.json
```

It measures three process-isolated trials per 8/4/2/1-step configuration in English
and Spanish, with model loading outside the generation timer. It verifies the
probe hash and records repeated audio hashes. These short samples help compare
computation; sustained narration, thermal and memory measurements still belong
on the target device before selecting a fallback.
