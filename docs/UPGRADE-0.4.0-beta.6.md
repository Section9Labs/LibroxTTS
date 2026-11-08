# Upgrade to LibroxTTS 0.4.0-beta.6 — Max resource recovery

This SDK prerelease builds on the beta.5 background-generation contract. Keep
all beta.5 entitlement, grant ownership, CPU fallback and cancellation wiring.
It does not publish the app or certify the reported iPhone memory/seek issue.

Pin exact `0.4.0-beta.6` in the app and every resolved graph after publication.
The seven v2 language packs, voice IDs, `.pocket` / `pocketTTSV1`, requested
sampling/chunking, output format and compatible prepared-audio identities remain
unchanged. No redownload, new product, model-selection migration or new UI is
required.

## Runtime changes

Max loads and converts checkpoint tensors individually, releasing each source
before converting the next. This reduces cold-load overlap without reducing
weight precision or changing FP32 model arithmetic. Prefill evaluates transformer
layers in bounded groups to limit temporary activation graphs. Ordinary single-frame
rendering retains its existing scheduling.

Decoder and residual streaming state are cleared on completion, cancellation and
failure. Failed operations retire model and random state and drain their selected
stream before returning. Host cancellation remains `CancellationError`; it is
never a request to restart playback or retry on CPU.

On iOS, the SDK checks available process memory and critical thermal state before
loading and at rendering checkpoints. Resource failures surface as existing
`NarrationRenderer.RenderError.memory` / `.thermal`. Preserve position, stop and
unload, and let the user resume after recovery. Do not immediately retry the same
expensive unit, delete downloads, or silently change the selected model.

Admission is conservative and cannot prevent OS termination between checkpoints.
The SDK does not claim a calibrated iPhone startup-step recommendation. Preserve
explicit saved settings and identify any automatic effective-step changes using
the existing realtime policy and rendered cache identity.

## Optional diagnostics

Before starting the serial narration job:

```swift
await renderer.setMaxResourceObserver { snapshot in
    // Store a bounded local record; do not block or call back into the renderer.
    // snapshot contains no book text, book IDs, or voice names.
}
```

`NarrationRenderer.MaxResourceSnapshot` reports phase, monotonic uptime, backend,
sampler steps, token/frame index when available, process footprint, available
process memory on iOS, MLX active/cache/peak allocations and thermal state. MLX
counters are process-wide. A completed unit's active memory is not peak process
footprint. Disable the observer with `nil` when no diagnostic capture is needed.

## Validation boundary

See the [resource-recovery evidence](validation/max-resource-beta6/README.md)
for exact measurements and tests.
Seeded PCM equality checks are technical regression evidence, not new listening
approval. Compact BF16 weight-storage experiments remain test-only because their
measured rendering slowdown was unacceptable for a default change.

App acceptance still includes the reported iPhone memory event and seek stall,
long narration, lock/unlock, grant expiration/denial, CPU fallback, interruptions,
1/2/4/8 steps, memory/thermal behavior and human listening. Keep the same simple
Basic/Plus/Max flow and download all seven Max packs separately through the shared
download action. No new export UI is required.
