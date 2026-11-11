# 0.7 architecture review evidence

Baseline: `v0.6.2`, `f75bacfbdc86c0c6dd81f0fb11cb9bcd160e49dd`.
Date: 2026-11-11. Baseline artifacts below precede runtime implementation changes.
Candidate artifacts and subsequent validation are described in the
[implementation report](../implementation-07.md).

## Fresh validation

- `swift test`: exit 0.
- `swift test -c release`: exit 0.
- `swift package dump-symbol-graph --minimum-access-level public --skip-synthesized-members`: exit 0.
- `swift package describe --type json`: exit 0.
- `git diff --exit-code HEAD -- Package.swift Package.resolved Sources Integrations Tests Validation .github`: exit 0.

Toolchain: Apple Swift 6.4.2, arm64, macOS 27.0.1 (26A434), Mac15,14,
28 logical CPUs. This does not qualify the minimum Swift 6.3 toolchain or devices.
The tests did not receive external model-asset environment variables. Opt-in
real-inference tests were skipped. No listening or hardware acceptance is claimed.
[`validation.json`](validation.json) contains command results, log hashes, local
log paths and runner summaries. Warnings remain, principally in dependencies,
with a Qwen Sendable conversion warning relevant to the review.

## Focused source-planning measurement

[`PlanningBaseline.swift`](PlanningBaseline.swift) calls the public
`TextNativeNarrationPlanner.plan` against **unmodified 0.6.2 objects**, using
Spanish Plus F1 and Max Caro Davy, an empty lexicon and default chunking options.
It repeats `La puerta estaba abierta y nadie regresaba, ` and takes prefixes of
512, 2,048, 8,192 and 16,000 scalars. There are clause commas but no terminal
sentence punctuation. This intentionally exercises long-sentence splitting;
it is not a representative audiobook corpus or the full `NarrationPipeline`.
Max's source-unit cap is 2,400 scalars; real token-aware acoustic chunking is not
part of this measurement.

Each case is run three times in one process; the median wall time is recorded.
Source generation and fingerprinting are outside the measured interval. Hashes
cover unit UTF-16 ranges, voice IDs and synthesis text, not every field in a plan.
All eight Debug/Release fingerprints agree. That is a narrow consistency check,
not the complete future compatibility suite.

| Input scalars | Plus Release median | Max Release median |
|---:|---:|---:|
| 512 | 0.938 s | 0.0042 s |
| 2,048 | 3.771 s | 0.0061 s |
| 8,192 | 14.828 s | 14.795 s |
| 16,000 | 28.910 s | 29.609 s |

Full results: [`planning-release.json`](planning-release.json) and
[`planning-debug.json`](planning-debug.json). An additional Release run of the
512/2,048 cases after other review build/probe commands finished is recorded in
[`planning-release-confirmation.json`](planning-release-confirmation.json).
That confirmation measured 0.949/3.807 seconds for Plus and 0.0044/0.0062 seconds
for Max at 512/2,048 scalars respectively, with the same plan fingerprints.

The initial Debug/Release probes and some build/symbol work overlapped on a shared
workstation. Thermal state, other apps and CPU placement were not controlled.
Do not interpret the Debug/Release ratio as an optimization result. These
baseline artifacts alone provide no A/B speedup, model timing, energy measurement
or physical-device result. Subsequent candidate comparisons are described in the
implementation report linked above.

The [`stack excerpt`](planning-stack-excerpt.txt) is from a one-second `sample`
of the Release probe. Its dominant sampled call path reaches
`TextNativeNarrationPlanner.swift:76` → `SpokenTextLexicon.text` → normalization
and repeated regex construction. This supports prioritizing text preparation;
it does not quantify a universal percentage of production narration CPU.

## Reproduce the planning probe

Run `swift test -c release` first. With the SwiftPM/Xcode build layout used here:

```sh
swiftc -O -I .build/out/Products/Release \
  docs/architecture-07/PlanningBaseline.swift \
  .build/out/Products/Release/KokoroNarration.o \
  .build/out/Products/Release/KokoroPronunciation.o \
  .build/out/Products/Release/PronunciationEnglish.o \
  .build/out/Products/Release/KokoroCatalog.o \
  .build/out/Products/Release/LibroxCTNative.o \
  -o /tmp/libroxtts-07-planning-release
/tmp/libroxtts-07-planning-release
# Short confirmation; each requested size still runs three times per model:
/tmp/libroxtts-07-planning-release 512 2048
```

Other SwiftPM build systems put modules and per-file objects under
`.build/arm64-apple-macosx/release`; adjust the linker inputs to that build's
actual outputs. Do not use a fresh source compilation with different code and
label it the recorded baseline. Keep the resources produced by SwiftPM in place.

## Inventory and interface artifact limits

[`inventory.json`](inventory.json) describes 31 active targets and 20 products.
Source line counts include tests/probes, omit dependencies/inactive experiments,
and are architectural context rather than a code-quality score.

[`api-baseline.json`](api-baseline.json) is a compact selection from the native
macOS symbol graphs: public/open USRs, module paths, declaration fragments and
availability, with synthesized members omitted. It contains 2,802 **module-symbol
entries**; reexports appear in more than one module. This is useful inventory,
not a complete compatibility checker. The raw graphs remain locally at
`.build/out/symbolgraph`. A release gate additionally needs iOS/Catalyst surfaces,
conformances, source-client fixtures, defaults and runtime/serialization contracts.
