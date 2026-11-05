# Librox Companion

Native macOS menu bar app for preparing Librox books with Chatterbox Multilingual. The Mac owns inference; readers submit durable requests and download verified audio through the same private iCloud account.

## Run

```sh
./script/build_and_run.sh
```

Requires macOS 15+, Apple silicon, the installed Librox Companion development provisioning profile, and the pinned native model assets. The default build is Release: Debug inference is deliberately rejected by the delivery diagnostic. The signed app is `dist/Librox Companion.app`. The Codex Run action invokes this script.

Open the menu bar book icon. **Your Library** automatically reads your existing Librox iCloud library, even while preparation is paused. Search or select a book to download its original file and prepare it on this Mac. Recently opened books show their synced reading progress. **Add Book…** remains available for local files. Import an unprotected EPUB, UTF-8 text file, or exact `.libroxbook` export and press its Prepare button. Requests from iPhone appear automatically after the iOS integration is installed. The worker polls every ten seconds while idle; this version does not require CloudKit push subscriptions.

**Pause Preparation** joins active work and preserves requests and completed audio. **Stop This Request** cancels this Mac reader's demand; another device's request remains independent. **Quit** joins inference, encoding and cloud operations before exiting. Opening at login is opt-in in Settings. No account, library or cloud reset is performed.

## Narration files

Settings → Narration Files selects a JSON manifest with `parameter` and `path` entries for `metallib`, `acousticCheckpoint`, `decoderWeights`, `decoderOracle`, `frontendDirectory`, and `stockConditioning`. Paths must remain available. The renderer validates the pinned assets; merely choosing a manifest does not establish model readiness. This Mac's manifest is in `~/Library/Application Support/LibroxCompanion/model-pack.json` and currently refers to its existing T9 model pack.

English and Spanish are exposed by the current verified planner. The underlying model is Chatterbox Multilingual; this app does not claim tested support for its other languages. AAC and ALAC are explicit choices. A codec validation failure is surfaced; there is no silent codec substitution or signal normalization. Listening approval remains pending until actual listening acceptance.

## Storage and identity

The local library lives in `~/Library/Application Support/LibroxCompanion`. Reader and worker have separate directories beneath the account partition, independent journals, and a single-worker filesystem lock. The default role storage limit is 20 GiB with 2 GiB free-space reserve. Storage exhaustion fails with an error; automatic eviction is not implemented.

The locally signed app uses `com.section9labs.Libros.Companion`, team `995PCLM9KH`, and private container `iCloud.com.section9labs.Libros`. It reads the actual signed CloudKit environment. The build defaults to **Production** iCloud to match the installed App Store/TestFlight Librox library. The existing development provisioning profile explicitly permits this environment; it is still a local development-signed binary, not a distributed release. Set `COMPANION_CLOUD_ENVIRONMENT=Development` when building for isolated diagnostics. The user deployed the narration schema on 2026-11-05; all ten required record types and fields were verified from a Production export. Reading the existing library requires no library-schema change.

EPUB extraction has its own identity (`companion-epub-swiftsoup-text-1`). It never pretends to match the iOS reader's extraction. For matching book/audio identity across hosts, use the phone's exact source provider or a `ChatterboxBookDocument` exported from it. The current app supports import and preparation, not a second audiobook player.

## Library assembly

- `LibroxChatterboxPlanning.ChatterboxCloudPreparedBookService`: actual reader service, private CloudKit content/control, source admission, durable retry, status, resolution and verified download. Does not depend on MLX or the native renderer.
- `LibroxChatterboxMac.ChatterboxMacCloudBookWorker`: resident native model, serial whole-book scheduling, verified segment upload and fenced completion.
- `LibroxChapterWorker`: account epochs, storage admission, immutable content identities, per-device wanted intent, worker claims and segment custody.

Claims do not expire by a wall clock. The same installation can recover only after its prior producer has joined or its process has died and its exclusive lock is reacquired. A different Mac cannot steal an uncertain claim. Keep the worker directory when restarting; manual deletion is not a recovery procedure.

## Validation commands

```sh
swift test --filter 'CloudLibraryTests|CloudOperationsTests|ChapterCloudBookWorkTests|BookImportTests'
COMPANION_CLOUD_ENVIRONMENT=Development ./script/build_and_run.sh --build
open -n 'dist/Librox Companion.app' --args --check-cloud /tmp/librox-cloud-check.json
open -n 'dist/Librox Companion.app' --args --check-delivery /tmp/librox-delivery-check.json
```

Run diagnostics one at a time with the normal worker paused. The delivery check uses two short self-authored English chapters and explicit ALAC, loads the real native model, writes Development iCloud data by default, and verifies reader downloads. A Production-signed build requires the explicit `--allow-production-check` flag to run this self-authored diagnostic against Production. Its adjacent directory retains independent reader/worker state for recovery. Do not run a build script while it is active: the script intentionally asks the running app to quit before replacing it. A `passed` result without `joined` is not a completed diagnostic. This is same-Mac role separation with real CloudKit, not physical-iPhone playback evidence.

The iOS implementation brief is [LIBROX-IOS-INTEGRATION-PROMPT.md](../../docs/LIBROX-IOS-INTEGRATION-PROMPT.md).

## Existing library access

`ChatterboxCloudLibrary` reads only the existing `CD_StoredBook` mirror. It fetches metadata and incremental changes every 45 seconds and downloads an original file only for a selected book. It preserves titles, original library IDs, content hashes, last-opened activity, progress and finished state; it does not change reading positions or instantiate a competing SwiftData mirror. The service clears its in-memory library on account change. Saved selections are account-bound. Librox does not currently persist the device that last opened a book, so the app reports synced activity without claiming iPhone versus Mac origin.

The read-only live check is `open -n "dist/Librox Companion.app" --args --check-library /tmp/librox-library.json`. It reports counts and verifies a selected original file without loading the narration model or writing to the library.
