# Approved expression SDK integration

This branch integrates the cumulative human-approved Round 07 into published
LibroxTTS 0.4.0-beta.1 source (`c61248927b285e162d1b3fb089b953ae0643f906`).
It is an opt-in qualification candidate, not a published SDK/model update or a
TestFlight delivery. The release owner retains all distribution ownership.

## Frozen acoustic contract

- Approved source tree: `7e3b07f4afd4c109023644a877d8f00996adaaec`.
- Graph manifest: `07166b8dbcc7de7d987e39bec031977eae8b86ca56d8c11ecb59ffe31619211e`.
- Graph packages and learned weights are unchanged from that approved artifact.
- The pinned factory selects `linear-two-step` / `late-context-residual-linear2-v1`,
  the protected terminal selector, narrator-owned role pool, and attached-reporting
  second pool. No later research is included.
- All ten generator steps, full native 44.1 kHz buffers, fixed nativeDynamics gain,
  bounded vocoder context windows and voice transitions remain intact. No silence
  removal, fades, crossfades or output truncation is added. Natural pauses remain off.

## SDK integration

`NarrationPipeline.plan(..., nativeExpression: true)` computes bounded per-unit
context, source roles and reporting evidence inside the SDK. It keeps at most two
neighbors on either side, never crosses paragraphs, and only applies context to
dialogue. Original source ranges, spoken readings and persistent cast choices are
preserved. Narrator units remain isolated. Blended voices retain the existing
isolated rendering path pending expression/blend listening qualification.

`CTApprovedExpression.configuration(directory:)` pins the approved graph manifest
and complete carry contract. `NarrationRenderer(storageRoot:resources:expressionDirectory:)`
loads it; the compact-directory initializer also accepts the pinned configuration
for independent qualification. A prepared expression unit is rejected if its
engine lacks the matching expression configuration, rather than silently using
the earlier gather algorithm. The default application path remains unchanged.

`BookNarrationUnit.nativeExpression` carries only its bounded source evidence.
`NarrationModel.renderIdentity(for:)` includes the graph, carry, context position,
role evidence and reporting evidence. The actor does not retain chapter evidence
between renders or style changes. GPU/CPU handoff preserves the CPU text encoders.

Approved graphs use the SDK's source/OS/architecture compiler cache after full
pinned-hash verification. Arbitrary research graphs retain their isolated temporary
compilation path. Carry buffers are released after their respective generator step;
no arithmetic or conditioning schedule is reordered. Neither change claims a
measured device speedup or whole-process memory saving.

## Evidence and limits

The optimized private harness is in `Examples/ApprovedExpressionQualification`.
It uses the actual SDK planner/renderer with trace capture off, saved cast/noise,
and all 14 archived cases (55 units), then warm GPU, CPU and return-to-GPU passes.
It verifies exact source evidence, full raw/delivered sample counts, per-unit voice
identity, offsets, and same-device GPU replay. CPU audio is not claimed bit-identical
to GPU. The Mac run compares with the frozen Mac GPU reference; an iOS run records
that comparison separately from same-device consistency.

Physical iPhone/iPad performance and listening are separate gates. The harness
switches backends explicitly; it is not the actual Librox playback queue, Lock
Screen or OS background execution. Human approval covers the presented English
and Spanish F1/M1 material, not all ten styles or all 31 languages. Existing shared
language availability/casts/readings remain intact. The reviewed reporting-clause
predicate is conservatively English/Spanish only; other languages retain the
approved role-pool fallback rather than unreviewed predicate expansion. Phoneme/
stress-dictionary equivalence, regional pronunciation and Plus Chinese remain open.

## Next release integration

Before enabling this in Librox, complete physical qualification and make a new
immutable versioned asset installation carrying both base DK and approved expression
identity. Reuse existing verified DK bytes and preserve the working DK/CT installation
until replacement verification/preparation succeeds. Do not change published
`plus-dk-coreml-preview-v2` assets or its hashes. Current qualification uses an
additive private graph directory, not a production download/update implementation.

Playback, preparation, opening/resume cache and voice preview must select the same
installed expression version and planning option. Every generation and prepared-PCM
cache must include the installed runtime identity. Retain current UI, saved cast,
blending and Natural pauses settings; do not enable an unsupported blended expression
path. The app's existing expression capability flag remains off until that integration
is ready. Ship via a new SDK version and exact resolved graphs, with a combined app
SHA, archive and verified TestFlight receipt owned by Release Manager.
