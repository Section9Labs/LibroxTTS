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

- **Voices:** six English and four Spanish candidates; three passages each. Alba,
  Jane, Vera, George, Peter Yearsley and Stuart Bell in English; Lola, Alba, Jane and
  George in Spanish. Cross-language voices are audition candidates, not accent endorsements.
- **Temperature:** 0.15, 0.30, 0.45; other parameters fixed.
- **Phrasing:** short (24/16 narration/dialogue targets, no short-sentence extension),
  balanced (48/32, short threshold 12), flow (72/48, short threshold 12). All use a
  96-token hard cap, whole-sentence preservation and a 2,400-scalar outer bound.
- **Sampler steps:** 1, 2, 4; other parameters fixed.
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

The direct engine now accepts bounded `samplerSteps` (1–8), defaulting to one on
every call. The shared narration renderer still uses one step. Choosing a winner
with a different temperature or sampler count requires carrying those settings
through the production profile/cache contract before app integration.

The page exposes actual chunk decisions, render duration, full settings and optional
ASR discrepancies. ASR is a content screen, not a narration-quality score; listen
to establish whether a flagged word is wrong or the recognizer made a mistake.
The audio has no loudness normalization, compression, pitch or speed adjustment.
The first pass selects a voice; the later passes tune it. Follow up on the preferred
combinations with long chapters and the target device before shipping a preset.
