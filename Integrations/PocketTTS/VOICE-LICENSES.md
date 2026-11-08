# Pocket TTS voice licenses

Reviewed for the SDK release on 2026-11-07. The software's MIT license does **not**
license the voices. Kyutai distributes the model and preset states under
[CC BY 4.0](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning).
The source recordings retain the separate terms below.

| Retained voices | Recording source | Recording license |
| --- | --- | --- |
| Alba | Alba MacKenna, Casual | CC BY 4.0 |
| Anna, Azelma, Charles, Eponine, Eve, Fantine, George, Jane, Mary, Michael, Paul, Vera | CSTR VCTK | CC BY 4.0 |
| Daan | CML-TTS Dutch, speaker 11290 | CC BY 4.0 |
| Bill Boerst, Caro Davy, Peter Yearsley, Stuart Bell | Voice-Zero / LibriVox | CC0 |
| Javert, Marius | Unmute voice donations (Butter, Selfie) | CC0 |
| Estelle | Kyutai / Unmute recording | CC0 |
| Giovanni, Lola | Common Voice Italian and Spanish clips, identified by Kyutai filenames | CC0 |

This is **23 voices**, each with a supplied state for seven language models:
English, French, German, Portuguese, Italian, Spanish and Dutch. These are 161
language/voice IDs, not 161 different speakers. Cross-language accent and delivery
must be auditioned; the recording license does not establish narration quality.

Sources: [Kyutai's recording credits](https://huggingface.co/kyutai/tts-voices),
[pinned source-to-preset mapping](https://github.com/kyutai-labs/pocket-tts/blob/28770c06f7deb1b65617834e60a6add7a4ff5b6d/pocket_tts/utils/utils.py),
[CML-TTS dataset license](https://openslr.org/146/), and
[Mozilla's Common Voice license declaration](https://www.mozillafoundation.org/en/blog/common-voice-18-dataset-release/).
The Common Voice and CML mappings rely on Kyutai's source filenames; this records
the declared provenance, not an independent chain-of-title certification.

## Withheld voices

- **Cosette:** Expresso recordings are CC BY-NC 4.0.
- **Jean:** EARS recordings are CC BY-NC 4.0.
- **Juergen and Rafael:** Kyutai supplies their states, but its recording-credit
  page does not identify their recording license. The model's CC BY label alone
  is not treated as documentation of those source rights.

All four IDs are rejected. New German and Portuguese selections default to Alba;
explicit saved IDs are never silently mapped to a different speaker. The v2
asset manifests omit all four. The earlier 25-voice development pack and its
measurements are historical and are superseded for this SDK release.

## Distribution and app acknowledgements

CC BY 4.0 allows commercial use with attribution, a license link and identification
of modifications. Preserve Kyutai's model credit and the selected recording's
credit. Each v2 pack includes structured `VOICE-CREDITS.json` with source URLs,
recording license, attribution and evidence links, plus `NOTICE.json` identifying
the unchanged tensors and Swift MLX port. `PocketTTSCatalog.attribution` supplies
the general model credit and `Voice.sourceRecordingLicense` exposes the recording
license for an app's voice information screen.

CC0 recording status does not remove the CC BY obligations for the model/state
distribution. Do not label the entire download MIT. No arbitrary reference-audio
cloning is included in this SDK integration.
