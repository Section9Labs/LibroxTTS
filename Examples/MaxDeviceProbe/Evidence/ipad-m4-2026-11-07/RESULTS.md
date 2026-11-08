# Max beta 4 on physical M4 iPad

Completed November 7, 2026 (America/Los_Angeles) on an iPad Pro 11-inch M4,
8 GB class, iPadOS 27.0.1 (24A446). Runtime source: SDK beta 4,
`ae216a446ce22533e628fc79b0318b19136f5a21`. Signed Release probe built with
Xcode's iOS 27.1 SDK. Native GPU execution on the physical iPad; no simulator or
Mac-generated audio substituted. Installed as `com.section9labs.MaxDeviceProbe`,
separate from Librox.

## Results

All 22 rendered units across six trials returned nonempty finite PCM. Temperature
was 0.3, with default adaptive chunking. Eight sampler steps were used except
the explicitly labeled comparison. Every recorded thermal state was nominal.

| Trial | Audio seconds | Render seconds | Highest post-unit footprint |
| --- | ---: | ---: | ---: |
| Tender English, 8 steps, Alba | 11.36 | 7.32 | 2.53 GB |
| Three paragraphs, 8 steps, George | 74.88 | 15.26 | 4.14 GB |
| Automatic-cast dialogue, 8 steps | 14.56 | 4.14 | 4.15 GB |
| Spanish, 8 steps, Lola | 23.12 | 16.65 | 4.62 GB |
| Tender English, 4 steps, Alba | 11.52 | 4.36 | 4.63 GB |
| Explicit three-voice dialogue, 8 steps | 16.56 | 2.93 | 1.34 GB |

The explicit cast was a separate app launch after updating the probe. The first
five trials shared one renderer process. First renders can include model loading,
validation and Metal setup; these are not controlled sampler-step benchmarks.
Memory values are decimal GB snapshots after units, not continuous peak tracking.

## App integration findings

1. The longer eight-step trial rendered about 4.9 times faster than playback.
   This supports keeping the requested higher-compute profile on this iPad.
2. Memory reached a 4.63 GB post-unit footprint after the mixed-language sequence.
   Do not infer that a 3–4 GB phone can sustain the same run. Investigate MLX
   cache/memory limits before broad lower-memory device qualification. This test
   does not prove a leak or identify the allocation source.
3. Automatic speaker detection recognized the dialogue but did not assign
   distinct voices for this fixture. Max's catalog gives all voices unknown
   gender; the shared allocator requires matching gender when the text supplies
   it. It therefore retained narrator fallback. Do not present automatic distinct
   voice casting as universal. Expose persistent manual cast assignments.
4. An explicit persisted cast carried Alba for narration, Anna for Clara and
   George for James through the shared pipeline and renderer. The second report
   records the ten units, including narrator speech tags between character turns.

## Evidence and limits

`initial-report.json` and `assigned-report.json` were copied from the physical
app's document container. Audio is retained locally under
`Benchmarks/Narration/results/max-ipad-2026-11-07/` and on the iPad in the test
app's Files folder. The initial report covers five trials; the later probe adds
the explicit-cast trial to its default sequence.

This is a short functional/performance check, not a listening-quality verdict,
whole-book thermal soak, production Librox lifecycle test, cold network download
test, or iPhone qualification. The iPhone remained unavailable. No SDK runtime
change or new release was needed for these tests. SDK beta 4 CI also passed.
