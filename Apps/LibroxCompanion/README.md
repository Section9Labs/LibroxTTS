# Librox Companion

Native macOS menu bar app for preparing Librox books with Chatterbox Multilingual. The Mac owns inference; readers submit durable requests and download verified audio through the same private iCloud account.

## Run

```sh
./script/build_and_run.sh
```

Requires macOS 15+, Apple silicon, the installed Librox Companion development provisioning profile, and the pinned native model assets. The default build is Release: Debug inference is deliberately rejected by the delivery diagnostic. The signed app is `dist/Librox Companion.app`. The Codex Run action invokes this script.

Open the menu bar book icon, choose **Enable This Mac**, then **Add Book…**. Import an unprotected EPUB, UTF-8 text file, or exact `.libroxbook` export and press its Prepare button. Requests from iPhone appear automatically after the iOS integration is installed. The worker polls every ten seconds while idle; this version does not require CloudKit push subscriptions.

**Pause Preparation** joins active work and preserves requests and completed audio. **Stop This Request** cancels this Mac reader's demand; another device's request remains independent. **Quit** joins inference, encoding and cloud operations before exiting. Opening at login is opt-in in Settings. No account, library or cloud reset is performed.

## Narration files

Settings → Narration Files selects a JSON manifest with `parameter` and `path` entries for `metallib`, `acousticCheckpoint`, `decoderWeights`, `decoderOracle`, `frontendDirectory`, and `stockConditioning`. Paths must remain available. The renderer validates the pinned assets; merely choosing a manifest does not establish model readiness. This Mac's manifest is in `~/Library/Application Support/LibroxCompanion/model-pack.json` and currently refers to its existing T9 model pack.

English and Spanish are exposed by the current verified planner. The underlying model is Chatterbox Multilingual; this app does not claim tested support for its other languages. AAC and ALAC are explicit choices. A codec validation failure is surfaced; there is no silent codec substitution or signal normalization. Listening approval remains pending until actual listening acceptance.

## Storage and identity

The local library lives in `~/Library/Application Support/LibroxCompanion`. Reader and worker have separate directories beneath the account partition, independent journals, and a single-worker filesystem lock. The default role storage limit is 20 GiB with 2 GiB free-space reserve. Storage exhaustion fails with an error; automatic eviction is not implemented.

The development app uses `com.section9labs.Libros.Companion`, team `995PCLM9KH`, and private container `iCloud.com.section9labs.Libros`. It reads the actual signed CloudKit environment. Development and Production are different databases: an App Store/TestFlight reader cannot consume this Development build's queue. Production signing, schema deployment and release are separate release work.

EPUB extraction has its own identity (`companion-epub-swiftsoup-text-1`). It never pretends to match the iOS reader's extraction. For matching book/audio identity across hosts, use the phone's exact source provider or a `ChatterboxBookDocument` exported from it. The current app supports import and preparation, not a second audiobook player.

## Library assembly

- `LibroxChatterboxPlanning.ChatterboxCloudPreparedBookService`: actual reader service, private CloudKit content/control, source admission, durable retry, status, resolution and verified download. Does not depend on MLX or the native renderer.
- `LibroxChatterboxMac.ChatterboxMacCloudBookWorker`: resident native model, serial whole-book scheduling, verified segment upload and fenced completion.
- `LibroxChapterWorker`: account epochs, storage admission, immutable content identities, per-device wanted intent, worker claims and segment custody.

Claims do not expire by a wall clock. The same installation can recover only after its prior producer has joined or its process has died and its exclusive lock is reacquired. A different Mac cannot steal an uncertain claim. Keep the worker directory when restarting; manual deletion is not a recovery procedure.

## Validation commands

```sh
swift test --filter 'CloudOperationsTests|ChapterCloudBookWorkTests|BookImportTests'
./script/build_and_run.sh --build
open -n 'dist/Librox Companion.app' --args --check-cloud /tmp/librox-cloud-check.json
open -n 'dist/Librox Companion.app' --args --check-delivery /tmp/librox-delivery-check.json
```

Run diagnostics one at a time with the normal worker paused. The delivery check uses two short self-authored English chapters and explicit ALAC, loads the real native model, writes Development iCloud data, and verifies reader downloads. Its adjacent directory retains independent reader/worker state for recovery. Do not run a build script while it is active: the script intentionally asks the running app to quit before replacing it. A `passed` result without `joined` is not a completed diagnostic. This is same-Mac role separation with real CloudKit, not physical-iPhone playback evidence.

The iOS implementation brief is [LIBROX-IOS-INTEGRATION-PROMPT.md](../../docs/LIBROX-IOS-INTEGRATION-PROMPT.md).
