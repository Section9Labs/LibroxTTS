# Librox app handoff — LibroxTTS 0.6.2

Integrate LibroxTTS **0.6.2**, which includes the approved source commit
`56393f12bcb33a51b78327a2d4b8ece75d2f4ea8` from
`fix/audio-led-chunk-progress`. Preserve concurrent app work and saved books,
positions, voices, styles and sampling settings. This is an SDK integration
handoff, not authorization to upload the app to TestFlight or the App Store.

```swift
.package(url: "https://github.com/Section9Labs/LibroxTTS.git", exact: "0.6.2")
```

Update every applicable package declaration, resolved graph and XcodeGen input.
For an app already pinned to the approved commit, retain its callback integration
when replacing the commit pin with this release. The runtime implementation in
that commit is preserved; the release adds documentation and validation receipts.

## Retained backend, assets and quality

Keep the [0.6.1 platform/download/playback integration](UPGRADE-0.6.1.md), using
the **0.6.2** package pin. iPhone/iPad use Core ML CPU; Mac/Catalyst retain MLX.
One acoustic backend is downloaded per device/language. Model bytes, asset
manifests, voices and styles are unchanged, so this SDK upgrade does not require
new model downloads. Existing on-device compilation receipts remain subject to
the SDK's normal manifest/OS validation.

The default remains Caro Davy / Calm, temperature 0.3, four sampler steps and
Careful reading. Preserve saved settings. Keep full-speed generation, bounded
streaming backpressure, the 12/30-second playback-buffer policy and the existing
memory/thermal/cancellation handling. Do not lower quality to hide a deficit.

## Continuous clause synthesis and cache migration

Adaptive phrasing now splits long sentences at existing clause punctuation near
the soft target. It keeps internal comma/semicolon endings and continuation case
instead of turning each internal request into a new sentence. A nearby natural
boundary may exceed the soft target to avoid tiny fragments; the hard token cap
still applies. Unpunctuated clauses stay intact up to that cap. `.keepTogether`
continues to protect the paragraph or fail explicitly.

This is an approved synthesis behavior correction, not a weights or sampling
change. Audio may differ from 0.6.1. `PocketTTSChunkingOptions.revision` is now
`pocket-continuous-clauses-2`; use `NarrationModel.pocket.renderIdentity(for:)`
in prepared-audio cache keys so old rendered audio is not reused as corrected
audio. Do not clear model downloads, user exports, books or reading positions.

## Audio-led text progress

`NarrationRenderer.renderPocketFrames(_:onTextChunk:receive:)` and both engines'
`renderFrames` accept an optional synchronous, throwing `onTextChunk` callback.
Existing callers can omit it. Each `PocketTTSChunkProgress` has:

- `text`: the prepared input chunk, not a transcript or original-source range;
- `startSample` and `endSample`: a cumulative half-open interval in emitted
  24 kHz mono source PCM, starting from zero for each render call.

The callback fires after all frames of a completed chunk have been accepted by
the receiver. It may arrive after some of that audio has already played. A
failed or cancelled unfinished chunk has no completion event. Enabling metadata
does not add audio, silence, resampling or a playback-rate adjustment.

Store events with the same unit/session generation as the audio queue. Translate
per-call sample ranges into the player's source-sample timeline, accounting for
queued unit offsets, seeks, rate changes and any output resampling. Drive visible
text progress from **played source samples**, never generation completion,
callback arrival or elapsed wall time. Hold the last known position during
starvation or when a usable interval is not yet available.

These are chunk boundaries, not word alignment or proof that every input word
was pronounced. Map prepared text back to the book conservatively; dictionary
substitutions or normalization can make direct source matching fail. Any
intrachunk interpolation remains approximate. Cached audio without stored chunk
metadata cannot claim this alignment; preserve the app's explicit fallback.

Both callbacks run on the engine actor and participate in cancellation and
backpressure. Protect shared state, avoid blocking the main/audio callback
threads, and do not launch an unbounded task per frame/event. Reject stale
events after pause/seek/book/account changes. Cancel and await generation before
unloading. A partial stream must not become a completed prepared-cache entry.

## Validation boundary and app acceptance

Matt approved the tested changes and accepted the Spanish Core ML Caro Davy /
Calm, seed-42 recording for continuity and word completeness. This acceptance
does not cover every language, voice, seed, playback rate or backend.

The prior 0.6.1 ten-minute locked-device benchmark is historical evidence, not a
new performance qualification of this changed chunking revision. Remaining work:

- Physical iPhone listening and text-follow behavior at normal/custom rates;
  open-book/listening views, manual navigation and long paragraphs.
- Calls/routes/interruptions, lock/background, chapter/book transitions,
  cancellation, memory and thermal behavior in the combined app.
- Controlled sustained Mac MLX throughput and current iPhone background speed.
- Broader listening across English/other languages, seeds, voices, backends and
  long unpunctuated input.

Run Debug/Release package/app checks appropriate to the integration and verify
all dependency graphs. Report actual device/listening results and remaining gaps
separately from successful builds and simulator tests. Retain the existing
Basic/Plus behavior, model asset identities and attribution.
