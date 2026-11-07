# Moby-Dick paragraph comparison

On 6 November 2026, Matt rated the initial English pipeline comparison “About the same” and asked us to select a complete paragraph from Project Gutenberg, suggesting Moby-Dick. That verdict does not establish an audible improvement. The candidate remains unaccepted for release.

The selected paragraph is Chapter 1, “Loomings,” beginning “There now is your insular city of the Manhattoes” and ending “Look at the crowds of water-gazers there.” It is one complete HTML paragraph, 68 words / 387 characters, from [Project Gutenberg](https://www.gutenberg.org/files/2701/2701-h/2701-h.htm).

## Controlled comparison

All three audition files use F1, English, 1x, mono 48 kHz PCM and -24 LUFS integrated loudness. No expressive waveform effects are added.

| Clip | Processing | Duration |
| --- | --- | --- |
| released.wav | Desktop reconstruction of SDK 0.2.1: two passages, per-passage loudness normalization, 220 ms boundary pauses, 24 kHz delivery, AVAudioEngine unity-rate time-pitch | 27.259 s |
| candidate.wav | Candidate shared planner: whole paragraph, fixed F1 gain, 44.1 kHz delivery, unity-rate bypass | 26.122 s |
| original.wav | Frozen original CT ONNX graphs, whole paragraph, same exact token IDs and initial noise as candidate Core ML | 26.122 s |

The original reference manifest was hash-verified. The public Core ML assets were checked against the SDK's pinned manifest. The released/candidate plans have different duration/noise tensor shapes, so they are not an identical-noise experiment; the original/candidate whole-paragraph conversion comparison is.

## Findings, not listening acceptance

- On this Mac, released AVAudioEngine time-pitch at rate 1 and bypass produced essentially identical aligned audio: correlation 1.0, 139.07 dB signal/error ratio. This does not support unity-rate processing as the cause of flat expression in this desktop test. It is not an iPhone hardware-route measurement.
- Core ML GPU versus original ONNX: exact tokens/noise and sample count, 35.04 dB whole-waveform signal/error ratio, correlation 0.999843. The error is localized but greater than the earlier reference fixtures; maximum raw-sample error is 0.1523. Do not label this sample-exact or assume perceptual equivalence.
- Core ML CPU versus original is similar (33.72 dB). GPU versus CPU is 50.58 dB. Text encoder outputs match the original at over 121 dB; final generator latents at 63.62 dB GPU / 62.34 dB CPU. Differences accumulate through synthesis and become larger in the waveform; switching off GPU does not remove them.
- Matt rated this Moby-Dick comparison “about the same but this one does not sound as bad as the book I tested.” It establishes no audible improvement and does not reproduce the reported severity. He identified the beginning of Electric Dreams as the failing case; investigation now targets that actual book and its locally cached audio. Private book text and audio are not repository fixtures.

Artifacts are local at `/Users/matt/Code/swift/librox-ct-native-assets-v2/moby-dick-comparison/`: passage/source, verified-reference render script, saved noise/token IDs, raw PCM, graph traces, `report.json`, `analysis.json`, `trace-comparison.json`, playback script and WAVs. Playback uses [AVAudioEngine offline rendering](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing). These files are desktop reconstructions, not recordings of Librox on Tachikoma.

These Moby-Dick renders used production library source `551a1b287f99f71d4910977f170ccc4e0b3cd034`; both GitHub CI runs for that revision passed. A subsequent private-book reproduction exposed a candidate planner failure on blank lines and long quoted sentences. The fix tokenizes within paragraphs, skips empty/ornamental tokens and permits nonspeaking prefixes during bounded scans; it changes the planning/cache revision. It is a reliability correction, not an accepted expression improvement. No model payload, installed app or published release changed.
