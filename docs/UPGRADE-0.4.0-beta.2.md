# Upgrade to LibroxTTS 0.4.0-beta.2

Pin exact `0.4.0-beta.2` in all SwiftPM graphs, including the app, LibrosKit and
validation packages. Regenerate the XcodeGen project and confirm every resolved
pin has the same immutable SDK revision. This beta adds the cumulative approved
Round 07 conditioning; rejected later research is excluded.

## Download and activation

The new public model is
[plus-dk-expression-round07-v1](https://github.com/Section9Labs/LibroxTTS/releases/tag/plus-dk-expression-round07-v1),
identity `librox-plus-dk-expression-round07-v1`. Its 40 pinned files occupy
514,894,479 logical bytes. An intact DK v2 installation reuses 514,512,198 bytes
(including verified identical weights copied into two new graph packages), leaving
382,281 new download bytes. This estimate does not apply to missing/corrupt files
or a fresh installation. Old DK/CT release assets and hashes have not changed.

Use `NarrationAssets.manifest`, `repositoryID`, `previousRepositoryIDs`,
`estimatedDownloadSize` and `reuseVerifiedFiles`; do not hardcode release URLs.
Reuse requires actual SHA-256 and byte-length verification, not equal filenames
or graph shapes. Stage privately and preserve the working installation/receipt
through cancellation or failure. Verify and prepare every replacement file before
atomic activation. Do not share writable inodes with the retained installation.
Keep the license and supplemental modifications notice with the installation.

## One generation, one installation

Capture the selected **installed** repository ID for a playback generation.
Pass it to both `NarrationPipeline.plan(..., repositoryID:)` and
`NarrationRenderer.load(..., repositoryID:)`. Apply the same rule to playback,
opening/resume prewarm, voice preview and diagnostic render paths. Do not substitute
`NarrationAssets.repositoryID(.plus)` for a retained installation's actual ID.

The renderer configures the approved encoders automatically for the new identity.
The planner supplies bounded dialogue evidence without retaining book-wide state
in the engine. Old installations continue working with their original planning
and validation. Preserve saved casts/readings and include installation, preparation
and unit render identities in PCM cache keys. Do not reuse previous-generation PCM.
SDK tests cover identity switches without changes to voice choices or source ranges.

## Audio and shared behavior

Preserve native 44.1 kHz Plus output, fixed nativeDynamics gain, all ten generator
steps and full output samples. No normalization, trimming, fades or crossfades
are added. The ten styles and 31-language cast/reading catalog remain available;
Basic keeps its own supported catalog. Retain Automatic language and the existing
shared voice cards/lists/waveforms and character settings.

Blended voices keep the existing isolated rendering path. Natural pauses remain
off by default. The general expression UI capability remains off: this release
adds approved context conditioning automatically for the new installation, not
an unqualified emotional-intensity control. Reviewed reporting predicates remain
English/Spanish; other languages retain the approved conservative role-pool fallback.

## Qualification boundaries

The versioned installation passes all 115 Mac qualification renders, including
95 exact GPU comparisons with the approved reference and 20 finite full-frame CPU
renders. Runtime source `320d63c` passed 115 native iPhone renders: 40 repeated GPU
units matched the first same-device renders exactly, with nominal thermal state.
Phone output was not byte-identical to Mac. Later packaging/identity changes were
verified separately; the final beta app has not yet been physically listened to.

The iPad is unavailable and remains unverified. Full Librox playback, background
behavior and listening on this generation are pending TestFlight review. Human
approval covers the presented English/Spanish F1/M1 comparisons, not every voice,
language or general emotional contrast. Native phoneme/stress-dictionary equivalence,
regional pronunciation and Plus Chinese remain open. Do not report this SDK/model
release as an installable app build; Release Manager owns the combined app archive,
upload and Apple processing/tester-group verification.
