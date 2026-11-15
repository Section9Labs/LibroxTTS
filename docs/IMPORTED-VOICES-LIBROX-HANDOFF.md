# LibroxTTS 1.1.1 — app voice import handoff

Update Librox to `https://github.com/Section9Labs/LibroxTTS.git`, exact version `1.1.1`. Add import and deletion to the existing Max voice management UI. Follow the app's repository/release-owner instructions and preserve unrelated work. Do not upload or publish the app as part of this task.

After import, a voice is an ordinary catalog voice: use the existing narrator picker, character picker, per-book selections, preview, planning, rendering, preparation/cache and playback paths. Do not build an imported-voice rendering path, pass new parameters through the pipeline, or recreate renderers after import. All existing SDK API signatures and synthesis defaults are preserved.

## Import, launch and delete

Own one `PocketTTSVoiceStore(directory:)` actor in a persistent Application Support directory separate from downloaded language packs (for example `ImportedMaxVoices`). This is the only new integration surface required for voice management:

```swift
let voiceStore = PocketTTSVoiceStore(directory: importedVoiceDirectory)

// At launch, before restoring narrator/cast selections:
let imported = try await voiceStore.voices()

// Native file importer; keep security-scoped access open until this returns:
let voice = try await voiceStore.importVoice(from: selectedURL)

// Existing APIs now include and resolve the imported voice:
let voices = NarrationModel.pocket.nativeVoices
let characters = NarrationModel.pocket.characterVoiceCatalog(language: voice.language)
// Existing NarrationPipeline.plan and NarrationRenderer calls stay unchanged.

// Explicit user deletion:
try await voiceStore.remove(voice)
```

`importVoice` validates and copies the package into managed storage, then registers it with the normal SDK catalog. Reimporting identical bytes deduplicates by content ID. `voices()` validates/reopens the store and restores registration after relaunch. `remove` deletes the managed file and unregisters it. Refresh the app's existing picker state after these operations. The renderer and native engines resolve voices on each request, including instances created before import.

Use a native file importer for `.libroxvoice` with a UTType conforming to data. The format contains prepared model-bound voice state; it does not accept WAV/MP3 input or perform cloning/training. Show the package display name and language in the normal voice rows; retain attribution in details. Never special-case a particular voice name.

Disk/hash/tensor validation runs on the store actor; await it from UI code. Keep security-scoped access open until import completes, then release it. Cancelled or invalid imports must not appear as successful installs. Do not bundle private voice files/recordings in source control or release assets.

## Existing pipeline and lifecycle

- Persist the returned `voice.id` in the existing narrator/cast settings. Use existing catalog APIs, including `PocketTTSCatalog.voice(id:)`, for lookup/language/download routing. The SDK supplies the correct ID, name and language. Do not construct IDs from display names or save process-local descriptors.
- Imported voices require the normal installed Max pack for their declared language. Existing download/readiness/preparation paths and Max entitlement checks remain in force. No model redownload or acoustic SDK replacement is needed.
- Continue using the selected voice ID and full `NarrationModel.pocket.renderIdentity(for:)` in prepared-audio keys. Different package bytes have different IDs; stock identities and 1.0 Max loudness defaults are unchanged. Imported voices pass through the same renderer delivery/level pipeline; voices without a frozen calibration profile use its existing unity-gain fallback.
- Query available delivery styles through the normal capability APIs. Current `.libroxvoice` packages contain one original voice state, so they offer Original, just like stock Original-only voices. Saved unsupported styles resolve through the normal style policy. Do not substitute a stock voice to manufacture a style.
- Keep existing phrasing, sampling, speed, highlights, cancellation, background, resource-budget and streaming policies. There is no imported-voice phrasing override or voice-name-specific behavior.
- On deletion, cancel dependent preparation/playback and handle affected saved selections with the existing unavailable-voice UI. A selected deleted narrator/character must not silently become another voice. The SDK prunes removed, unused imported IDs from cast pools without recasting characters; selected missing IDs still fail explicitly. Run normal voice-availability checks before cache lookup so prepared audio cannot bypass deletion. Other books/voices and downloaded packs remain usable.
- Model-pack uninstall must not delete private imported packages. Do not add private tensor iCloud sync in this first integration. A synced selection is unavailable on another device until that package is imported there.

## Acceptance

Build with the released dependency and exercise the real file importer: import, preview, select for narration and a character, persist/restore, reimport without duplication, then delete. Confirm engines/renderers that existed before import can use it. Reopen after app relaunch before restoring selections. Use at least two packages or names; no behavior may depend on a specific display name.

Test cancellation, incompatible/malformed package, corrupt installed file, missing language pack and deletion of both an unused and a selected voice. Check normal stock preview/playback, downloading/uninstall, book switching, existing audio caches and character casting. Distinguish build/automated tests from actual iPhone/Core ML and Mac/MLX listening, background and lock-screen acceptance.

The private audition package available locally is `/Users/matt/Documents/Codex/2026-11-15/llevara-pocket-voice/victoria/Victoria.libroxvoice`. Its name is test data, not an SDK policy. Earlier native audition evidence and its sentence-omission limitation are documented in `docs/validation/imported-voices/README.md`; preserve normal app qualification rather than claiming import validation guarantees spoken-word accuracy.

Return the app commit, validation, and exact user steps to import/delete a voice. State what is implemented versus installed or shipped. This SDK release does not publish the Librox app.
