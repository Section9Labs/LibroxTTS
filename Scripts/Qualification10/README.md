# Physical-device qualification

These probes use separate task-owned applications. They never install over Librox
or access its container. `prepare.py` creates an XcodeGen project using a supplied
checkout and local, verified assets; it requires the Caro/Calm voice fixture and
includes available delivery fixtures. It uses the repository's development team;
change that field for another team's device.

Create baseline and candidate projects in an isolated temporary directory, using
published `v0.9.0` for the baseline. Build Release for the same physical device and
install the two `com.section9labs.libroxttsqualification10.*` applications. Keep
the qualification app foreground and unlocked. Do not run both at once.

Launch arguments:

- `--label NAME --seconds 0`: twelve English exact-audio cases, steps 1–8,
  specialized/shared graph revisits, voice/style changes and continued passage.
- `--label NAME --seconds 1800`: repeat the fixed four-step Caro/Calm passage for
  at least 30 wall-clock minutes. Each render must reproduce the first PCM hash
  and all chunk events. Thermal state and sampled footprint are recorded.
- `--fresh`: copy the bundled original assets to a new label-specific directory
  before preparation. Includes source copy and SDK compilation/validation costs
  in `setupSeconds`. The OS/compiler's global cache is not purged.

The harness aborts if it receives frames while backgrounded. It writes
`Documents/NAME/report.json` atomically after each render and `complete.txt` only
when the entire requested loop finishes. **Wait for that marker before stopping
the process or switching applications.** Partial report files are not passes.
`environment.json` separates preparation/setup from first accepted audio. The
render timers exclude report serialization; the duration loop uses wall time.

Example device operations (supply your connected device identifier):

```sh
xcrun devicectl device process launch --device "$DEVICE_ID" \
  com.section9labs.libroxttsqualification10.candidate \
  --label candidate-soak --seconds 1800
xcrun devicectl device copy from --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier com.section9labs.libroxttsqualification10.candidate \
  --source Documents/candidate-soak --destination /tmp/candidate-soak
```

Use `Scripts/compare-10-device.py` on completed baseline/candidate output folders.
For speed, run short fresh-process workloads in ABBA order with the same thermal
state. A cool three-minute baseline and a hot thirty-minute candidate are useful
for memory/audio qualification but are not a paired throughput experiment.

After collecting receipts, uninstall only these two qualification bundle IDs.
Retain the host app, installed models, playback state and other developers' probes.
No physical iPhone, background playback, battery energy or listening approval is
implied by this foreground iPad harness.
