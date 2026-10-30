# Librox Pro companion: implementation and verification brief

Matt's direction, 29 October 2026: retire the experimental quantized phone
renderer and concentrate on full-quality Mac rendering. This brief applies
BAMA's `os-integrations`, `performance` and `mac-design` guidance to the existing
LibroxCompanion. It does not establish a running backend or approved UI.

## Responsibility and native surfaces

Keep the Catalyst reader. Librox supplies extracted document text, account and
network lifecycle, demand, settings and playback. The shared library owns chapter
identity, planning, expressions, rendering, scheduling, verification and source
maps. T3 owns the native companion package and its menu/settings integration.

Use one native menu-bar status panel, with a concise status label and access to
Settings and Librox. Reuse Librox typography, semantic colors and accessibility
conventions. No separate catalog, custom window chrome, web dashboard or duplicate
reader. Show actual imported books and chapter states: queued, rendering,
publishing, ready or failed. A completed remote chapter is not locally available
on the phone until download and decode verification finish.

Display the active book/chapter, measured progress when available, queued/ready
counts, storage and the last actionable error. Never animate invented progress.
An unavailable backend says it is unavailable; imported metadata is not a rendered
chapter. Empty states explain how to request a chapter from Librox.

## Controls and lifecycle

- Librox's master enable/disable setting controls the companion. Start at Login
  is a separate, explicit opt-in. Packaging does not silently register a helper.
- Disabled means no new claims. Cancel and join active work before releasing its
  claim or declaring shutdown complete. Preserve queued demand and finished audio.
- Account changes fence every asynchronous result with the account/session epoch.
  Returning to the same account does not authorize old callbacks.
- Sleep, expired leases, lost acknowledgements and network failure require durable
  reconciliation. Do not publish from an uncertain lease or show a local success
  because a cloud request was submitted.
- Prevent idle sleep only for active, authorized rendering; release that assertion
  on completion, cancellation and failure. Do not keep the Mac awake while idle.

## Rendering and resource policy

The first cloud scope uses installed stock voices. Saved phone recordings and
conditioning stay on the phone; preserving them is not upload authorization.
Retain full-quality Standard and the ten-step multilingual acoustic trajectory.
The next candidate replaces CPU acoustics with a strictly loaded native Swift
MLX GPU seam, after weight/state and numerical validation. No model switch from
an advertised token rate.

Keep model tensors resident and avoid host copies/synchronization inside the
acoustic loop. Transfer the completed waveform once where possible. Bound caches,
queued buffers and concurrent work; use backpressure rather than unbounded task
creation. Start with one worker. Two workers require measured aggregate throughput,
first-chapter latency, memory and thermal evidence with isolated caches and RNG.

Measure Release builds: cold load, warm generation, cadence, final copy, selected
watermark policy, encoding and verified artifact commit. Report audio seconds per
wall second and time to first ready chapter. Target complete RTF <= 0.20; existing
CPU controls do not meet that target. Watermark opt-out is explicit and part of
render/cache identity; the prior pair found no reliable complete-pipeline speed win.

## Acceptance before a test-ready claim

1. Standard-only SDK build, unchanged safety gates and retained regression tests.
2. Strict native acoustic weight/state inventory, fixed-input trajectory validation
   and complete generated-only English/Spanish audio for Matt's listening gate.
3. Durable request/outbox/lease/fence and crash-recovery tests, then actual private
   CloudKit transfer and verified full-chapter download/playback.
4. BAMA `ux-design`, `build-and-verify` and `test-mac-app` on the actual signed
   companion: light/dark, accessibility/keyboard, empty/error/offline/account states,
   menu actions, disable during work, quit, relaunch and explicit login behavior.
5. Real one-versus-two-worker throughput and sustained thermal/storage checks.

Unit tests, a compiled menu shell and fake cloud transports cover different gates.
No release, merge, TestFlight upload or device workload is authorized by this brief.
