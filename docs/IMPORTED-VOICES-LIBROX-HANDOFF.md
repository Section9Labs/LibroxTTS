# Librox custom Max voice import — implementation prompt

Implement the first custom-voice import flow in Librox, using the SDK changes on branch `codex/max-imported-voices` in `/Users/matt/Code/swift/librox-tts-imported-voices` (based on SDK v1.1.0). Keep unrelated work intact. Follow the app's repository and release-owner instructions. Do not ship or upload a build as part of this task.

The user-approved voice is **Victoria**, Spanish, derived from the accepted Libro.fm preview reference. The ready-to-import file is:

`/Users/matt/Documents/Codex/2026-11-15/llevara-pocket-voice/victoria/Victoria.libroxvoice`

This first flow imports a prepared voice package. It does not accept WAV/MP3 files or run cloning/training. The package already contains the voice state. Do not modify stock voice files, manifests, or model checksums, and do not bundle Victoria's private package or recordings in the repository.

## SDK dependency

Use this SDK worktree as a local Swift package for integration/testing, or pin its reviewed commit after it becomes available remotely. The changes are not in the released v1.1.0 tag; do not pretend that selecting that tag includes them. Preserve the existing supported dependency setup and coordinate its final pinned revision with the SDK owner.

## User experience

Add **Import voice…** to the existing Max voice picker/settings. Use a native file importer for `.libroxvoice` (declare a UTType conforming to data). While import validates, show progress and prevent duplicate submissions. On success, show **Victoria · Spanish**, an Imported indicator, a Preview button, and the existing narrator-selection action. Keep built-in voices available and unchanged.

The first import must immediately appear in both the appropriate narrator picker and Spanish character-voice picker, with the existing per-book selection and preview behavior. Use the package display name; do not expose tensor filenames, hashes, paths, or model jargon in the normal UI. Imported voices only have Original delivery. Retain attribution in a voice-details view. Reimporting the same package should reuse the existing voice without creating duplicate rows.

Handle cancellation, invalid/incompatible packages, corrupt installed files, missing Spanish Max assets, and a previously selected voice that was removed. Never silently replace a missing custom voice with a preset. If custom storage is corrupt, show an actionable error while keeping stock voices usable; retain saved unavailable IDs until the user explicitly changes them.

## Integration contract

1. Own one `PocketTTSVoiceStore(directory:)` actor in a persistent Application Support subdirectory such as `ImportedMaxVoices`. Keep it separate from downloaded model packs and downloaded-pack uninstall/cleanup. Store methods perform synchronous disk work on their own actor; await them from UI code. Keep security-scoped access active until `try await store.importVoice(from: url)` returns, then release it. The store copies the validated package into its own directory; it does not retain the external URL.
2. On launch, `try await store.voices()` reloads validated descriptors. Publish the resulting `[PocketTTSImportedVoice]` as the app's imported-voice snapshot. Persist selected `voice.id` strings in existing book/cast settings. The ID includes a content fingerprint and fits the existing 64-byte cast limit. Do not invent IDs from names or serialize process-local descriptors/paths.
3. Use `model.nativeVoices(importedVoices: snapshot)` and `model.characterVoiceCatalog(language: code, importedVoices: snapshot)` throughout voice selection, validation and previews. Pass the snapshot to `resolvedVoiceID`, `makeVoiceCast`, and `expandingVoiceCatalog` wherever those are used. The no-argument APIs intentionally remain the built-in catalog.
4. Pass the same snapshot to `NarrationPipeline.plan(..., importedVoices: snapshot)` and `NarrationRenderer(..., importedVoices: snapshot)`. The renderer captures it at initialization. Cancel/await obsolete preparation and safely unload/replace the renderer before rendering newly imported IDs; preserve existing book-switch lifecycle protections. Never assume updating the picker automatically updates an existing renderer.
5. Resolve custom voice language from the descriptor or combined native catalog. Audit existing `PocketTTSCatalog.voice(id:)` calls in `ListeningCenter`, download routing, model keepers, previews, and preparation; that catalog intentionally knows only built-in voices. Victoria requires the normal Spanish Max pack. Use the normal download/install mechanism and keep the user's Max entitlement checks.
6. Pass the selected voice ID through render units and existing audio-cache keys. Do not key audio by display name. A different package gets a different ID, so it must not reuse audio from the previous voice. Metadata and voice tensors are checked against the installed model contract; imported files are revalidated at render time.
7. Imported voices are language-specific: Victoria is Spanish. Offer Original delivery only. Saved styled settings resolve to Original in planning; direct backend requests for unsupported styles throw. Do not synthesize alternate emotional styles by substituting a built-in voice.
8. Removal uses `try await store.remove(voice)`. Explain effects on affected saved selections, cancel dependent preparation, refresh the snapshot, and preserve unavailable selections for explicit user resolution. Other voices and downloaded packs must remain usable. Do not add iCloud sync of private voice tensors in this first step; a selection synced to another device should display as unavailable there until that package is imported.

## Victoria audition settings

Use the profile that passed the native sample's word-by-word ASR check for Victoria's initial preview and the end-to-end test book:

```swift
let victoriaPhrasing = PocketTTSChunkingOptions(
    narrationTargetTokens: 32, dialogueTargetTokens: 32,
    maximumTokens: 32, shortSentenceTokens: 0)
// Pass as pocketChunking: victoriaPhrasing to NarrationPipeline.plan.
```

Use normal sampling (temperature 0.3, four steps) and Original delivery. The package stores voice identity, not these book settings. Persist this choice using the app's existing per-book phrasing mechanism; do not replace other books' saved settings or change global SDK defaults. The 48-token default grouping omitted a sentence in this audition on both native backends; the 32-token profile included all intended words. This is a verified sample, not a guarantee for every book passage. Keep the app's existing content/long-book qualification expectations.

## Acceptance

- Build the app with this SDK, import the supplied Victoria package through the real file importer, preview it, select it for a Spanish book, and play actual Max narration.
- Quit/relaunch; Victoria remains listed and selected. Confirm the same ID is used after reimport, without duplicates.
- Select Victoria for an explicitly assigned Spanish character, persist/restore the cast, and confirm the assignment is used during narration.
- Test import cancellation, invalid package, changed installed file, removal of a selected voice, and a missing Spanish model pack. A removed or incompatible voice must not silently speak as a stock voice.
- Confirm built-in voice preview/playback, normal model download/uninstall, and existing book-switch cancellation still work.
- Exercise the actual iPhone/Core ML playback path and the Mac/MLX path where available. Report device listening and background/lock-screen checks separately from simulator/build evidence.
- Return the implemented commit, concise validation evidence, and the exact steps Matt should use to import and audition Victoria. State clearly what is implemented versus installed or shipped.
