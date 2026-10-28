# Vendored runtime provenance

Source: https://github.com/iliasaz/chatterbox-coreml

Exact original revision: `b8288834e783f3a6210757fbaf62f9014220bff9`.
Only upstream `Package.swift`, `Sources/`, and `LICENSE` were copied. Tests, model
fixtures, examples, application projects and Git metadata were omitted. The original
MIT license is preserved and an adapter resource carries the attribution.

Local changes are exhaustively recorded in `UPSTREAM-PATCH.diff`:

- Remove the unavailable upstream test target; tests live in the adapter package.
- Add optional explicit/per-model `MLComputeUnits` to `VoiceCloner` without changing
  legacy caller defaults. The adapter always supplies its own policy.
- Add bounded reference encoder duration (legacy default 15 seconds); adapter V3
  uses 6 seconds / 150 T3 conditioning tokens. Acoustic context remains 10 seconds.
- Preserve full case for en/es in multilingual V3 tokenization; other languages
  retain upstream behavior until separately verified.
- Expose the successful T3 load configuration for telemetry, without claiming residency.
- Add opt-in bounded cross-request decode/synthesis scheduling, preserving each
  request's conditioning and options, with ordered awaited output and joined shutdown.
- Cache one exact conditioning prefix per assembler, keyed by speaker float bits,
  prompt tokens and exaggeration bits; expose host timing/cache-hit diagnostics.
- Add cooperative cancellation at prediction and hot-loop boundaries and before watermarking.
- Expose optional aggregate decode profiling and reject complete text/generation
  budgets that exceed the loaded prefill window or KV cache before inference.
- Add an optional fixed-flow-padding override, retaining upstream defaults when nil.
- Correct canonical V3 multilingual prefill: two position-zero BOS rows and
  lexical zeroing before learned text-position addition in the unconditional lane;
  update context admission to 36 fixed rows. EN/ES shared-conditioning row parity
  is tested separately from encoder and acoustic parity.
- Add canonical EN/ES prompt/speech-input assembly and an acoustic-only,
  serialized token synthesizer for separately validated native decoders. The
  latter loads no Core ML T3 model and requires successful Perth watermarking.
  A public sampler wrapper retains the existing host sampling policy.
- Add bounded multilingual V3 conditioning-file validation for private saved
  voice profiles (shape/dtype/offset/token/finite checks; not identity validation).
- Add an explicit environment-gated first-CFM-step fixture capture for private
  synthetic-reference diagnostics. It writes nothing without that opt-in and never
  overwrites an existing destination directory.

No learned weight was modified by these source changes. A separate reviewed
S3Tokenizer graph repair is an explicit model artifact, not silently embedded here.
The adapter currently accepts repaired graph SHA
`e869885d4e03bbcd2462422b0589ebd5c6f8b8f4893fbc3f25b6f8ccb61b279a`
only with weight SHA
`3c80a10d8e75f79cc5e500c5e07c50db43e4ac27a60925d98130a882579713da`.

Evaluation models:

- `iliasaz/chatterbox-multilingual-coreml` revision
  `295edc75a44a4ac22ef8344780a1ec06b63a0d0b`.
- `iliasaz/perth-coreml` revision `f17228757ad4876c8e13f0cd606758ce1ea5e4de`.

`Package.resolved` records every fetched Swift dependency revision, including
upstream branch dependencies. Retain that lockfile for reproducible evaluation.
`source-freeze.json` hashes adapter/runtime files used for the source handoff;
the package README is included. Separately owned DeviceProbe files are outside it.
