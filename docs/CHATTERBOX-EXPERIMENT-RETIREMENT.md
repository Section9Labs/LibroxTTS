# Experimental decoder retirement

On 29 October 2026 Matt rejected build 298's experimental stock voice sound and
punctuation-boundary stalls, then explicitly requested removal of the experiment
and its models. All experimental Q8 V1/V2/V3 and associated Q4 runtime, study,
model and generated listening artifacts are retired. Do not restore, download,
test or offer these profiles again.

The retained renderer exposes Standard (`mixedFloat16Accurate`) only. Its pinned
weight/reference hashes, original numerical gates, default arithmetic, memory,
thermal and audio checks remain unchanged. Grouping, overlap, logical tensor
copying, cache identity, voice creation UI and explicit watermark policy remain.
Old experimental profile strings no longer parse; app integration must explain an
unavailable selection instead of silently changing a user's voice.

The exact local deletion inventory and preserved Standard/Mac relocations are in:

`/Volumes/T9.2025/LibroxTraining/deletion-manifests/chatterbox-8bit-retirement-2026-10-29.json`

Non-quantized Mac qualification assets were moved to
`/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01`.
Old frozen reports retain their historical paths; rebind and independently freeze
any future experiment before execution. No old model job was resumed.

The full-quality Mac model roots and original licensed inputs are preserved.
User books, downloads, reading place, saved voices, recordings and private
conditioning are outside this deletion scope. SDK git history is not rewritten.

Phone public asset cleanup is tracked separately in the manifest. MAIN owns the
independently installed build 220 session; this chat has not deleted phone files,
terminated that app or replaced it. Its former build 298 PID is absent. Never
mistake completed local cleanup for completed phone cleanup.

The active implementation is the Swift-native Mac Pro chapter worker and native
companion described in `MAC-COMPANION-DESIGN.md` and `CHAPTER-WORKER-CONTRACT.md`.
