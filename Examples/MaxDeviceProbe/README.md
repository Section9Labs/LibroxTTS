# Max physical-device probe

Isolated iOS app exercising the shared LibroxTTS planner and renderer. It has its
own bundle ID and does not replace Librox or modify its data. This probe was added
after SDK beta 4; it does not change the published SDK runtime.

Place the verified English and Spanish v2 pack directories at `Assets/en` and
`Assets/es`. Those weights are ignored by Git. Generate with `xcodegen generate`,
then build the `MaxDeviceProbe` scheme in Release for a signed physical device.
Launch with `--run` or tap **Run device tests**.

The default run renders eight-step English tender narration, a three-paragraph
longer reading, automatic dialogue casting, Spanish, a four-step comparison, and
an explicit three-voice character cast. Launch with `--run --assigned-only` to
run only the explicit cast and save it separately in `Documents/AssignedResults`.
All use temperature 0.3 and SDK default adaptive chunking. Results are written to
the app's `Documents/Results`: six WAV files and an incrementally saved JSON
report, including source text, voice IDs, cache identity, duration, rendering
time, post-unit physical footprint and thermal state. The footprint measurements
are snapshots, not continuously sampled peak memory. Comparisons use independent
sampling draws, not a controlled fixed seed. Concatenated audio uses SDK output
directly, without additional playback cadence processing.

The app cancels generation when it becomes inactive. Do not start another app or
lock the device during the performance run. Generation keeps the screen awake;
that override is cleared on completion or loss of foreground activity.

Bundled assets isolate runtime testing from download transport. This does not
test production app settings, cold network download, playback lifecycle, all
seven languages, or sustained thermal behavior over a whole book. Listen to the
saved WAV files separately; numerical completion is not narration-quality
acceptance. Physical iPad results do not qualify an iPhone.
