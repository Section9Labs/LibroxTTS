# Max voice metadata

Automatic character casting uses source-corpus gender metadata for the twelve
VCTK voices below. Other presets remain unknown until documented metadata is
available. These fields describe the source recording; they are not inferred
from a display name or predicted from a voice sample.

Source: Yamagishi, Veaux and MacDonald, **CSTR VCTK Corpus 0.92** (2019),
[University of Edinburgh dataset](https://datashare.ed.ac.uk/handle/10283/3443),
`speaker-info.txt` extracted from the official `VCTK-Corpus-0.92.zip` archive.
The archive was read with HTTP ranges; audio was not downloaded. The mappings
to preset names use the existing v2 pack's `VOICE-CREDITS.json` recording paths.
The corpus is CC BY 4.0; existing acknowledgements retain its authors.

| Preset | Source speaker | Corpus gender |
| --- | --- | --- |
| Anna | p228 | F |
| Azelma | p303 | F |
| Charles | p254 | M |
| Eponine | p262 | F |
| Eve | p361 | F |
| Fantine | p244 | F |
| George | p315 | M |
| Jane | p339 | F |
| Mary | p333 | F |
| Michael | p360 | M |
| Paul | p259 | M |
| Vera | p229 | F |

All seven language variants use the corresponding speaker recording. New casts
can use this metadata to assign compatible voices. Expand existing cast metadata
through `model.expandingVoiceCatalog(in:)`; preserve manual assignments and
already assigned voices. Ambiguous attribution still uses the narrator.
