# Default Max voice levels — 1.0 candidate

The user explicitly authorized changing **default Max / Pocket narration loudness**.
This is an intentional delivery change. Raw `PocketTTSEngine` and
`PocketTTSCoreMLEngine` samples remain unchanged; Basic and Plus remain unchanged.
The SDK applies the same fixed voice/language/reference-style gain in buffered and
streaming `NarrationRenderer` output. Both narrator and character voices use it.
Prepared Max audio gets a new delivery identity; model/download identities stay put.

Calibration uses three neutral passages per language, with two separate holdouts,
23 original voices and every published style for the four reference speakers in all
seven languages. English and Spanish are measured on both Core ML CPU and MLX CPU;
the other five use MLX CPU. This does not certify Core ML output in those five
languages, MLX GPU level equivalence for the full corpus, every text, or listening quality.

The offline meter is FFmpeg `ebur128`, implementing integrated loudness/true peak
measurement described by [ITU BS.1770](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I).
The target of −26 LUFS is an engineering choice, not a requirement of that standard.
The [policy](targets.json) records the target, boost limit, style offset bound and
peak headroom. The generator reads **calibration rows only** when selecting gains.
Holdouts assess generalization; they do not select per-profile gains.

The complete corpus contains 3,375 raw recordings and 525 distinct delivery
profiles. Three passages per profile/backend select gains; two are held out.

Every profile has one fixed gain. Expressive styles retain their measured offset
from the same voice's Neutral reference, bounded to ±3 LU. This preserves dynamics
within speech and limits extreme differences between reference performances. It
does not infer emotion or invent intensity controls. A memoryless soft knee only
protects unexpectedly high boosted transients above amplitude 0.9; any activation
in the measured corpus is reported explicitly. There is no sentence-by-sentence
normalization, lookahead, resampling, silence trimming or timing change.

Reproduction:

1. Install the catalog-pinned base and optional style packs using SDK asset APIs.
   The probe supports `pocket-tts-probe --download-styles ROOT LANGUAGE` for the
   complete style pack. Keep installation and rendering roots isolated.
2. Run `Release10LoudnessTests` with `LIBROX_LEVEL_ASSETS`, `LIBROX_LEVEL_OUTPUT`,
   `LIBROX_LEVEL_CORPUS`, `LIBROX_LEVEL_LANGUAGES`, `LIBROX_LEVEL_BACKEND`, and,
   for reference styles, `LIBROX_LEVEL_STYLES=all`. The corpus is `corpus.json`.
3. Run `Scripts/measure-voice-levels.py` on completed raw recording directories.
   It verifies every raw sample count and SHA before measurement.
4. Run `Scripts/calibrate-pocket-levels.py` on those reports. It emits the frozen
   Swift gains and `profiles.json`, including the policy/manifests in the revision.
5. Run `PocketNarrationLevelAuditTests` with colon-separated `LIBROX_LEVEL_REPORTS`
   and an empty `LIBROX_LEVEL_DELIVERED` directory. This applies the actual Swift
   production transform and measures its processing time.
6. Measure the delivered directory, then run `Scripts/summarize-pocket-levels.py`
   to compare held-out results and export direct before/after Float32 WAV files.

The WAVs are for human acceptance. Matching hashes, meters and tests cannot certify
naturalness or expressive quality. Release promotion remains pending listening.

## Measured results

All 3,375 recordings (283,286,400 samples, 3.28 hours) were passed through the actual Swift production transform. Sample counts are unchanged.

Neutral includes Original and Neutral reference profiles. The table reports the
spread of each profile's median over the two withheld passages, in LU.

| Language | Backend used below | Before | After | Widest single held-out passage after |
|---|---|---:|---:|---:|
| en | coreml-cpu | 15.70 | 2.55 | 3.10 |
| es | coreml-cpu | 4.75 | 2.35 | 3.40 |
| fr | mlx-cpu | 15.95 | 4.35 | 5.70 |
| de | mlx-cpu | 16.60 | 3.45 | 5.30 |
| pt | mlx-cpu | 6.40 | 3.15 | 3.60 |
| it | mlx-cpu | 15.45 | 4.10 | 5.00 |
| nl | mlx-cpu | 13.70 | 2.95 | 3.70 |

All neutral calibration/holdout spread goals in `targets.json` pass on each
measured backend/language. English and Spanish Core ML/MLX metrics agree at the
meter's resolution; that is not a claim of cross-backend bit-identical PCM.

**The zero-peak-safety-activation goal is not met:** 27 of 283,286,400 samples
were affected, in two German holdouts (Giovanni Original: 21; Peter Tired: 6).
Those clips are included in the listening exports. Every other measured sample
uses only the frozen constant gain. The highest measured delivered true peak was
−0.3 dBTP; none reached 0 dBTP. Gains were not refitted to those held-out peaks.

Production scaling took 0.304 seconds for 11803.6 seconds of audio (1.07 ns/sample), about 0.57 ms per 22.16-second passage on this Mac. Total gain lookup time was 4.83 ms; the first lookup was 46.7 µs.
This is isolated processing time, not an end-to-end app/playback benchmark.

See `results.json`, `processing-overhead.json`, `profiles.json` and the three raw
meter reports plus `delivered-levels.json` for all rows. The level revision is
`pocket-level-v1-41466443134c33e7`.

Human listening remains **pending**, including the two German peak-safety cases.
