# Speed-regression repair evidence

These receipts use published 0.9.0 as baseline and the `44c25af` raw-engine speed
fix. The fixed 32-Float32 detachment retains the earlier memory ownership changes.
The default narration-level change is measured separately in `../loudness-review`.

- `audio-matrix.json`: 78 cases, Core ML / MLX CPU / MLX GPU, exact PCM and events.
- `profile-abba.json`: three ABBA blocks, three warm repetitions per process,
  same 22.16-second English Caro/Calm passage, exact WAV bytes.
- `profile-stability.json`: follow-up ABBA with ten warm renders per process to
  check aggregation sensitivity in the shorter repeated-process run.
- `backend-coreml-final.json`: cold, preview, warm, book, voice/language switch
  and slow-receiver sidecar timings with exact PCM/events.
- `device-pilot.json`: early short physical pilot; not substituted for final soak.
- `device-final.json`: final fresh/warm ABBA and 30-minute candidate soak.
- `device-qualification.json`: exact device audio/events and sustained memory
  comparison with the previous immutable 0.9 device soak.
- `repeated-render-memory.json`: isolated Mac process, 24 synchronous renders.

Reproduce with the existing commands in `../architecture-10/README.md`, using
`benchmark-10-profile.py --rounds 3` and `benchmark-10-backends.py --backends coreml`.
The stability follow-up uses `benchmark-10-profile.py --repetitions 10` (one ABBA).
The local toolchain remains Xcode 27.2 / Swift 6.4.2; timings are descriptive shared
host results, not cross-device guarantees. Each benchmark records binary hashes.
