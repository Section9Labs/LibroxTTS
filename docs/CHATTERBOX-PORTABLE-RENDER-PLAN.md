# Portable exact chapter rendering options

`LibroxChatterboxPlanning` is a Reader-safe SwiftPM product exposing `ChatterboxChapterRenderOptions`, `ChatterboxChapterRenderPlan` and typed request/plan errors on iOS, Catalyst and macOS. It has no MLX or native Mac acoustic target dependency. It still uses the existing `LibroxChatterbox`/CoreML adapter and narration support transitively; this is not a claim that those existing dependencies or resources disappear. Importing/creating a plan does not initialize a model.

The native Mac product retains its reviewed local API names as aliases: `ChatterboxMacChapterRequest`, `ChatterboxMacRenderPlan` and `ChatterboxMacRenderPlanError`. Actual resident loading, decoder gates and GPU rendering remain Mac-only. Source/options constructor failures are the public `ChatterboxChapterRequestError.invalidSource`; renderer runtime classifications remain separate public types.

```swift
import LibroxChatterboxPlanning

let options = try ChatterboxChapterRenderOptions(
    text: exactSource, language: "es", delivery: .smaller,
    grouping: .compatibleNarration(maxCharacters: 160),
    performanceDirections: reviewedChapterDirections, seed: 42)
let plan = try ChatterboxChapterRenderPlan(request: options)
let payload = plan.encoded()
// The forthcoming SDK intent transport persists this payload and source identity.
// The app does not invent a recipe or reconstruct model controls from hashes.

let admitted = try ChatterboxChapterRenderPlan.decode(payload, source: exactSource)
```

The versioned canonical payload carries source SHA-256/UTF-16 length, language, explicit delivery, direction, grouping budget, UInt64 seed and every authored annotation's UTF-16 range, named delivery/strength and optional actual exaggeration/CFG/temperature controls. It preserves absent versus explicitly empty directions. Annotation text is reconstructed only from the independently admitted exact source, not rewritten or duplicated in the packet.

Actual Float32 controls travel as UInt32 IEEE bit patterns. Signed zero and non-round decimal values therefore survive transport exactly; UInt64 seeds are never narrowed to a floating representation. Restoration goes through the original finite/range validators and source-bound direction constructors. This changes no arithmetic, sampler, solver, model, precision tolerance, voice or source text.

The public decode entry admits at most two MiB before parsing, at most 4,096 annotations and the existing 131,072-UTF16 / 393,216-UTF8 source bounds. It rejects unknown versions, fields, delivery/style/strength labels, invalid grouping, nonfinite/out-of-range controls, stale source bytes, expression-digest mismatch, partial graphemes, overlapping/unsorted ranges and noncanonical encodings. There is no public Codable shortcut or silent default/fallback. No payload option selects model files, private voice conditioning, a shortened solver, another precision policy or watermark behavior.

On the worker, `ChatterboxMacResidentRenderer.bindChapter(plan:submission:gate:)` restores the complete options using its own admitted `ChapterSubmission`, validates its current session before/after awaits, and recomputes the canonical request using the **actual resident backend**. Its render key and account must match the expected request before any rendering can begin. Changed backend, seed, controls, grouping, delivery or source cannot be replaced with defaults merely because a recipe digest was received. A producer's epoch never authorizes the worker.

A plan is neither a demand/claim nor proof of approval, account access, model readiness or playable audio. Immutable authoritative Reader intent publication, portable-plan persistence, current wanted/read-set checks and the actual Worker/service/catalog remain separate dependencies. Source publication or a restored plan alone must never start inference. The app must continue to use the unavailable factory until a reviewed committed dependency and separate signed-host runtime authority are supplied.

Validation uses pure planning and fake backend identities: exact control bits, extreme UInt64 seed, optional direction shape, canonical bytes, stale NFD source, invalid/unknown fields, malformed annotations and a fresh Worker rebind that rejects another backend/seed/old epoch. These are not model output, quality, speed, signed-process, live account or cloud qualification. Preserve approved audio samples; no new unchanged audition or model run is implied.
