Pocket TTS model packs for the LibroxTTS native Swift MLX integration.

Seven optional packs: English (current October 2026 default), French, German,
Portuguese, Italian, Spanish and Dutch. Each contains 25 preset voice states,
a tokenizer, current configuration, weights and attribution. Cosette and Jean
are excluded because their source recordings are noncommercial.

These assets require the Pocket TTS SDK integration; they do not replace Plus
assets or change any user's selected model. GPU inference is a Mac development
path pending physical iPhone/iPad qualification. No Librox app release is implied.

Source: Kyutai Pocket TTS `28770c06f7deb1b65617834e60a6add7a4ff5b6d` and public
preset model snapshot `a7056f505a4a8ca72d8b5fb1440071d6f1a35739`.
Model tensors are byte-identical to that snapshot; runtime layout/dtype conversion
happens locally in Swift MLX. Model weights: CC BY 4.0, Kyutai. Code: MIT.
Retain the per-pack NOTICE and VOICE-CREDITS files when redistributing.

Manifest paths are flattened with `--` in release filenames (for example
`es--model.safetensors` installs as `es/model.safetensors`). SDK manifests pin
every file size and SHA-256. Publication tooling verifies GitHub's upload digests.
