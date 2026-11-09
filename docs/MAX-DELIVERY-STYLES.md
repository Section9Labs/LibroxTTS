# Max reference-based delivery for audiobooks

LibroxTTS 0.4.0 adds 364 reference-based preview performances:
13 styles for four speakers, encoded independently for each of seven languages.
The default for new Max books is **Caro Davy / Calm**, with Careful reading,
temperature 0.3 and four sampler steps. Matt accepted the English book scene for
default narration on 2026-11-08. Existing books retain their saved selections.
Other voice/style combinations and non-English performances remain previews.
Use `PocketTTSDeliveryCatalog.isPreview(voiceID:style:)` for contextual labels;
style-only `isPreview` is conservative and cannot express speaker acceptance.

## Reading behavior

Initialize new books with `PocketTTSNarratorPreset.defaultNarrator(language:)`
and persist its voiceID, delivery, chunking and sampling fields. A pipeline call
with no explicit narrator and no saved cast selects these defaults. Supplying a
voice or cast preserves the previous Original/balanced behavior unless the host
passes saved or preset settings explicitly. Never use absence of a delivery
setting alone as permission to change an existing book.

The reader can change the narrator and delivery style for a book. Prose,
attributions and speaker labels keep that narrator style across chapters.
Original uses the existing voice state unchanged. Calm, Neutral and the other
styles select different reference performances of the same named speaker;
Neutral is a synthetic performance and is not an alias for Original.

Optional character styles use stable `BookVoiceCast` speaker IDs. Unassigned or
unattributed dialogue uses Original, even when the narrator uses Calm. Persist
the cast and `PocketTTSBookDelivery` with the book. A voice change must also
revalidate its style; never silently substitute another speaker or Original.

The existing sentence/paragraph and speaker boundaries remain authoritative.
Within a unit, Pocket's continuation carries previous text/audio through its
internal chunks using the selected style. Each new unit starts from its own
voice state, so a character or style change does not inherit the previous
speaker's emotional reference. This does not add acoustic continuation across
independent units or chapters.

For a manually edited passage, set `unit.pocketDeliveryStyle` before cache lookup
and render. An override applies to the complete planned unit. To style only part
of a larger unit, replan that passage with correct source ranges first; do not
insert acting instructions or emotion tags into the book text. No automatic
emotion classifier or style-state interpolation is implemented. Styles follow
the existing planner's speaker roles; they do not improve speaker detection.
Unrecognized quoted passages can remain with the narrator. Review the cast and
planned assignments when precise character performance matters.

## App integration

Keep Max above Plus. Keep narrator selection separate from Delivery and from the
existing advanced sampling controls. Label temperature **Variation**, with a
description explaining that more variation may reduce consistency. Do not call
temperature an emotion-intensity slider. Keep existing quality-first sampler
defaults and background CPU/GPU routing.

Use `PocketTTSDeliveryCatalog.publishedStyles(voiceID:)` for downloadable choices;
use `installedStyles(voiceID:in:)` off the main actor for verified installed
choices. A source recording or enum case is not evidence of a usable download.
The first candidate references are Bill Boerst, Caro Davy, Peter Yearsley and
Stuart Bell. Other voices continue to offer Original only.

```swift
import LibroxTTS

let preset = try PocketTTSNarratorPreset.defaultNarrator(language: "en")
let narratorID = preset.voiceID
let installed = try PocketTTSDeliveryCatalog.installedStyles(
    voiceID: narratorID, in: modelDirectory)
// Offer only the returned choices. This example is run after Calm is installed.
guard installed.contains(.calm) else {
    throw PocketTTSDeliveryCatalog.DeliveryError.missingOrInvalidAsset
}
var delivery = preset.delivery
let plan = try await NarrationPipeline().plan(
    chapterText, model: .pocket, bookID: bookID, chapterID: chapterID,
    narratorVoiceID: narratorID, language: "en", cast: savedCast,
    characterVoices: true, pocketChunking: preset.chunking,
    pocketSampling: preset.sampling, pocketDelivery: delivery
)
// Persist plan.cast and delivery before playing newly assigned characters.
for unit in plan.units {
    let deliveryIdentity = NarrationModel.pocket.renderIdentity(for: unit)
    // Include this along with model/assets, voiceID, text and existing settings
    // in both live and prepared-audio keys before querying the cache.
    let samples = try await renderer.render(unit)
    // Commit the successful unit's samples and original source range together.
}
```

Add a character assignment with
`delivery.characterStyles[stableSpeakerID] = .worried`, after verifying that
character's voice supports and has installed that style. The narrator style
does not apply to that character. If character attribution is unavailable, the
SDK does not invent a character/style assignment.

Use the same plan and renderer for reading, preparation, export and auditions.
Changing a style invalidates affected audio through `renderIdentity(for:)`;
Original retains the previous identity. Hosts must include
`PocketTTSBookDelivery.cacheIdentity` when deciding whether to rebuild an entire
chapter plan. Retire any
in-flight generation before applying changed settings.

## Optional asset installation and release

For the new default, `NarrationAssets.downloadPocketNarratorPreset(to:language:)`
installs the base language model plus Caro/Calm and credits in one operation.
Background-transfer hosts use `manifestPocketNarratorPreset(language:)` and
`preparePocketNarratorPreset(in:language:)`. Its manifest supplies the full size
and hashes. Existing base-only installations remain valid for Original voices;
install the selected delivery state before changing them to Calm.

Each language needs states encoded with its exact checkpoint. An English export
cannot be copied into the Spanish pack. Emotion references are currently English;
cross-language style retention and pronunciation require independent auditions.

`PocketTTSDeliveryCatalog.manifest(language:)` exposes a separate pinned optional
manifest. For a single performance use
`PocketTTSDeliveryCatalog.manifest(voiceID:style:)` and
`NarrationAssets.downloadPocketDeliveryStyle(_:voiceID:to:)`. This includes its
credits and licenses; use the manifest's download size in the UI. To download
all styles in a language use
`NarrationAssets.downloadPocketDeliveryStyles(to:language:)`. Background
URLSession hosts download that manifest's files and call
`NarrationAssets.preparePocketDeliveryStyles(in:language:)`. Use the same root as
the base Max pack. Serialize installation against active rendering. Preparation
checks the base pack and style hashes and applies background-readable file
protection. Rendering checks the selected state hash before model allocation.

Prepare candidates with `Scripts/PocketTTS/export_delivery_styles.py`. The
exporter pins Voice-Zero commit `490cfbee850a6d409076f477c766f567000a79b6`, checks
source Git blob IDs, retains credits/licenses, and requires the authorized
Kyutai cloning-enabled checkpoint. It checks shared inference weights against
the shipped pack before exporting. It does not publish anything. The SDK only
loads exported states; it does not embed Python or require an audio encoder on
the phone.

For preview distribution, publish the immutable optional assets and bundle
their `delivery-LANGUAGE.json` manifests in `Sources/KokoroCatalog/PocketTTS/`.
Local audition builds may temporarily bundle candidate manifests and install
candidate states without a release. Do not distribute an SDK advertising those
manifests before the hosted files are available. Preview distribution is for
listening evaluation; promotion to a recommended narrator requires human review.
For a revised state, change the delivery catalog identity and release tag so
prepared audio from old states cannot be reused.

## Audition and acceptance

Compare Original, Neutral and Calm for sustained prose. Compare Happy, Sad,
Worried and Surprised for dialogue before trying stronger performances. Keep
temperature, sampler steps, seed and text identical for the first comparison.
Then test Variation separately. Include a long passage with internal chunk
boundaries and a sequence that alternates narrator and characters.

`Scripts/PocketTTS/audition_delivery_styles.py` generates direct WAV comparisons
using the existing English/Spanish reflective, descriptive and dialogue texts.
It holds seed, temperature, steps and phrasing constant, records binary/state
hashes, and fails if a selected preset is missing. Its default compares the
four voices in Original, Neutral and Calm. Alternating-character playback must
also be reviewed through the shared book pipeline in the app.

Use `--phrasing short` for a controlled comparison with smaller targets. Initial
ASR screening flagged repeated/missing endings with some balanced-grouping clips,
including Original. Short grouping resolved both initial spot checks; this is
word-screening evidence, not a listening verdict. Preserve the user's explicit
phrasing settings and keep Delivery, Phrasing and Variation as separate controls.
The SDK exposes the same 24/16-token, no-short-sentence-grouping configuration as
`PocketTTSChunkingOptions.carefulReading`. Use it for new books and offer it as **Careful reading** without
overwriting existing saved phrasing. Whole sentences still stay together when
they fit the hard token cap.

Listen for speaker identity, intelligibility, expressive restraint, unnatural
breaths, harshness, pacing and abrupt transitions. A higher temperature or a
cleaned reference does not guarantee a better narrator. Human listening remains
the acceptance gate; checksums, builds and ASR do not establish that quality.

Settings credit text for the eventual release:

> Some delivery styles use synthetic emotional reference performances from
> Voice-Zero, based on LibriVox recordings and created with Chatterbox and
> Resemble Enhance. Reference samples: CC0. Pocket TTS model and exported voice
> states retain the applicable Kyutai CC BY 4.0 attribution. Individual speakers,
> source links and processing details are included in the voice-pack credits.

Sources: [Voice-Zero](https://github.com/OwenTyme/voice-zero),
[emotional references](https://github.com/OwenTyme/voice-zero/tree/main/voices-emotion),
[Pocket export API](https://kyutai-labs.github.io/pocket-tts/CLI%20Commands/export_voice/).
