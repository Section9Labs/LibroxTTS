# Max physical-device probe

Isolated iOS app exercising the shared LibroxTTS planner and renderer. It has its
own bundle ID and does not replace Librox or modify its data. This probe was added
after SDK beta 4; beta 5 adds background execution tests.

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

The default foreground performance run cancels generation when it becomes inactive. Do not start another app or
lock the device during the performance run. Generation keeps the screen awake;
that override is cleared on completion or loss of foreground activity.

Bundled assets isolate runtime testing from download transport. This does not
test production app settings, cold network download, playback lifecycle, all
seven languages, or sustained thermal behavior over a whole book. Listen to the
saved WAV files separately; numerical completion is not narration-quality
acceptance. Physical iPad results do not qualify an iPhone.

## Background execution

The probe has a separate signed Background GPU Access entitlement. Use an
explicit test App ID and a provisioning profile containing that capability.
The production app needs its own entitlement and profile.

- `--run --background`: CPU generation while real prebuffered narration plays.
- Add `--prefer-gpu`: request a real foreground iOS 26+ GPU grant, await its
  launch handler, then generate with `.backgroundGPU` after entering background.
- Add `--fresh-buffer`: render the long foreground buffer in this process first.
- Add `--retire-grant`: deliberately finish the grant during the first GPU
  render, await cancellation and retry CPU. This exercises the shared retirement
  path; it does not claim the OS expiration handler was induced.
- Add `--four-steps` or `--one-step` for explicit lower-compute comparisons.
- Add `--long` for a three-paragraph English passage without language switches.
  It queues four genuine narrated buffer passages first, to measure CPU resource
  budgeting without starving the audio session during slower generation.

Wait for `Documents/BackgroundResults/report.json` to say
`waitingForBackground`, then press Home or launch another app. The report saves
application state, granted/supported GPU flags, actual completed backend,
playback progress, duration, memory snapshots and thermal state. State 2 means
background. The normal probe run still cancels when inactive; only this explicit
background-audio test keeps the generation job alive. Stop the test app before
starting another run so new launch arguments take effect.

This harness currently requires iOS 26 for its background test entry point;
the SDK CPU backend and production fallback support iOS 18+. Older-OS device,
lock-screen, system-induced expiration and production reader tests are separate.

The background probe first verifies that an unowned `.backgroundGPU` request
is rejected, then requests a grant normally. iOS CPU rendering is paced to leave
CPU headroom; this can be substantially slower than playback.
