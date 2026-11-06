# Copyable Librox iOS implementation prompt

Implement Librox’s iPhone integration for Mac-assisted Chatterbox Multilingual audiobooks. Deliver both flows: request preparation from the phone, and discover and play an audiobook that was already started on the Mac. Use Broken Stars as the real Mac-prepared acceptance case. Complete the code, meaningful tests, signed device build, and real iCloud-to-iPhone playback verification; do not stop at a plan or placeholder.

The iOS app repository is `/Users/matt/Code/swift/Libros`. The SDK and companion repository is `/Users/matt/Code/swift/librox-tts-chatterbox`, branch `codex/chatterbox-macos-pro`. The verified implementation baseline is `1e3d309719da1c22ee4e18d0027913992c68023e`; inspect newer changes and pin the actual revision used. Read each repository’s AGENTS.md, current worktree/status, reader/audio architecture, and `Apps/LibroxCompanion/README.md` before editing. Preserve concurrent work. The Mac is actively preparing Broken Stars and a separate monitor is following it: do not stop, rebuild, install over, or relaunch that active producer without coordinating a necessary repair. Do not activate the old companion shell.

Use the concrete `ChatterboxCloudPreparedBookService` from `LibroxChatterboxPlanning` and the existing verified file-player integration. The Mac worker is `ChatterboxMacCloudBookWorker`. Replace any nil `PreparedBookProvider.makeContext` or `makeConnection` placeholder with working assembly. Keep MLX, `LibroxChatterboxMac`, native model assets, and worker journals out of the iOS target. Extend the portable SDK where the missing discovery/adoption behavior requires it; inspect the implementation instead of assuming that API already exists.

Deliver the following:

1. Connect to the existing private iCloud account.

Use signed container `iCloud.com.section9labs.Libros`, its private database, and the app’s actual signed environment. The installed companion uses Production; the phone must match. Resolve `CKContainer.accountStatus()` and `userRecordID()`, construct `ChapterCloudAccountIdentity`, open a fresh `ChapterAccountSessionGate` epoch, and assemble `ChatterboxCloudPreparedBookService.open(container:account:session:gate:deviceID:readerDirectory:storagePolicy:authorizeTransfer:)`, then `connect(session:)`. Persist a stable phone installation UUID and account-partitioned reader storage with an explicit disk budget. Never copy the Mac’s device identity, outbox, worker directories, or account constants. Preserve the companion’s user-initiated CloudKit scheduling and bounded timeouts; its former utility/background scheduling caused requests to time out before sending bytes.

2. Discover existing Mac-prepared audiobooks automatically.

Refresh discovery when the library appears, the app returns to the foreground, the account changes, and the user refreshes. Observe preparation updates while the relevant screen is active, with bounded polling/reconnection where push is unavailable. Join discovered audio to the existing library by original file SHA-256, with a validated library-ID association where available. Never match solely by title. The existing `CD_StoredBook` mirror is the book library, not the audiobook catalog; keep its records and reading positions intact. Recently opening a book does not request narration.

`books(session:)` currently returns scope/title/requested summaries. Add a public, verified discovery-details path exposing enough immutable source and render metadata to associate and adopt an existing preparation: full scope, original file identity, extraction revision, ordered section keys, exact render settings/model identity, and validated content/read-set references. Validate account binding and live membership before trusting these details. Do not fetch all audio or copy full book text merely to populate library rows. Handle duplicate titles, changed originals, and multiple narration versions explicitly. Retain discoverability of completed audio independently of whether a Mac is currently running or someone has cancelled their preparation demand; assess and implement the required additive catalog/retention behavior rather than assuming active-request listings already provide it.

3. Adopt the existing audiobook without regenerating it.

The current `preparedBook(scopeID:session:)` restores the local outbox; it does not import another device’s preparation. Current resolution also expects this device’s confirmed read set. Implement a supported, idempotent adoption operation that validates the remote scope and content, creates the phone’s own durable reader/demand state as required by the protocol, and reuses the existing verified source content and published audio. Do not borrow the Mac’s intent revision or fabricate upload acknowledgements.

Adoption must preserve the exact scope identifier, extraction, section ordering, model/voice configuration, codec, seed, and render identities. Do not invoke `begin` with the phone’s different extraction or current default settings and accidentally create a second audiobook. Do not re-upload/re-render already verified content just to make local bookkeeping happy. Recover adoption after offline use, restart, interrupted publication, or account revocation. If the remote metadata is insufficient, finish the portable SDK and compatible publisher support rather than adding a UI-only workaround. A completed adopted audiobook must remain playable with the Mac asleep; incomplete audio should wait for the Mac while retaining the available prefix.

4. Map companion narration sections to the reader correctly.

The companion uses extraction revision `companion-epub-swiftsoup-parts-2`. Unsplit sections have keys `spine:<originalIndex>`. Split sections have `spine:<originalIndex>:utf16:<start>-<end>`, where the range is in the companion’s exact extracted text for that original spine entry. Empty/silent entries remain in order. A companion narration index is not an original EPUB spine index.

For an adopted audiobook, preserve this source contract and build a verified mapping between its exact text/ranges and the iOS reader’s locations. Prefer sharing the portable extraction/mapping implementation where appropriate. Do not relabel a different extraction revision, assume offsets from different extractors are interchangeable, or estimate word timing proportionally. Whole-book audio playback must work even before a reader-location mapping is available; disable only unsupported synchronized highlighting/text-based seek and show a clear explanation. Seeking by verified audio position and section navigation must still work. Support seamless transitions between split parts of the same original chapter.

5. Keep the phone UI minimal and useful.

On a matching book, show Preparing, Partially available, Ready, or an actionable error from verified service state. Offer Listen when verified audio is available, including while later parts are being prepared. Show waiting for Mac when playback reaches the available prefix. Support resumed playback, chapter/section navigation, lock-screen/background playback, and the existing player controls. Keep technical IDs, model paths, and cloud infrastructure out of normal UI. A voice catalog entry is neither proof the Mac is awake nor proof a book is ready. A global upload count or continued rendering after an earlier failure does not prove completeness.

6. Implement verified segment playback.

Use `resolve`, both `successor` overloads, and `download`, or their extended adoption-aware equivalents. Download the current segment and a bounded small prefetch window. Retain `ChatterboxBookSegmentDelivery` and `ChapterLocalSegmentArtifact` throughout queued playback, and open files through `withFileAccess(session:gate:)`. After every await and before installing audio, validate the account epoch, scope, this phone’s wanted/reader revision, and seek generation. Use verified rendered unit maps and `localStartFrame` for positioning. A missing next segment waits; it must not replay stale audio.

Validate each chapter’s final prefix and seal, account for silent entries, and accept whole-book completion only at the verified SDK `.endOfBook`. Persist playback position separately from preparation demand. Seeking may reprioritize unfinished work using the adopted preparation’s section index and section-local UTF-16 offset; translate original reader positions through the mapping first. Seeking and pausing playback must not create a new book identity or cancel preparation.

7. Preserve phone-initiated preparation as a separate flow.

For a book without a compatible existing audiobook, offer Prepare Audiobook on Mac. Build a cancellation-aware `ChatterboxBookSourceProvider` from immutable original bytes, with a SHA-256 and versioned extraction contract. Preserve original spine identities and silent entries; explicitly map any necessary bounded parts. Never navigate the visible reader to extract text, silently truncate content, or substitute a different extractor under an existing revision.

Fetch the real `catalog(session:)`, use its descriptor’s `prepareBook(source:settings:session:)`, set the title, and call `begin(_:source:priority:session:)`. Return promptly after durable intent while SDK-owned extraction proceeds. English and Spanish are supported by the current planner. AAC and ALAC are explicit choices: no silent codec fallback, sample normalization, or relaxed validation to conceal a failure. Keep `listeningApproval == .pending` until genuine approval. Stop Preparation cancels only this phone’s request, not another device’s demand; provide clear behavior when the Mac’s independent request remains active.

8. Handle recovery and lifecycle correctly.

For phone-owned requests, call `retryPending(session:)` on reconnect, restore exact settings with `preparedBook(scopeID:session:)`, and resume incomplete extraction with `resumeSourceAdmission`. Give adopted requests an equivalent durable recovery path without re-extracting under a different identity. Subscribe to updates, retain the newest snapshot, and reconnect after transient failures. Service status is metadata, not custody of playable media. A receipt’s confirmed server revision acknowledges only that device’s exact intent.

On account changes, sign-out, shutdown, and relevant host transitions, synchronously stop accepting results and call `stopRequests`, cancel and join original work, await `close(session:)`, then close the old gate and release storage. Cancellation alone is not completion. Preserve same-account durable state and verified cache within the storage policy. Honor iOS background execution and network policy through `authorizeTransfer`; do not promise indefinite background execution or unload the active player during ordinary navigation.

9. Use the real Broken Stars preparation as the adoption acceptance case.

Known identifiers are test evidence, not production hardcoded constants:

- Book: Broken Stars, Ken Liu.
- Original EPUB SHA-256: `07309c2c9afcb0c6614d6c075b6cd003c2120976d8d730be3a6ec4fe01f6ff65`.
- Active Production scope: `a7b37739fdee2474d80f88e10de0fb5e3fee1e90280f5b1913494663e64d397f` (lossless ALAC, explicitly selected by the user).
- Extraction: `companion-epub-swiftsoup-parts-2`; 62 original EPUB spine entries produce 63 narration parts, including silent entries.
- Active delivery is lossless ALAC. The earlier AAC scope `e06a3b806375c5f961e37e1459d4f0435f2a95ffc1c0f8d40fb1cd17dbb9b677` remains preserved but its preparation demand is cancelled; do not select it as the acceptance target.

Refresh its live status. It is not yet proven complete. The user approved the new ALAC preparation after three AAC segments failed decoded-sample validation and the same PCM passed ALAC without modification. Do not hide missing/failed parts or mark the whole book Ready. Adopt the active ALAC scope exactly; do not restart, duplicate, or switch its codec as an adoption shortcut. Surface failures and coordinate any producer repair with the active companion work.

10. Validate both flows and deliver the implementation.

Test discovery on a fresh phone reader directory; identical titles with different originals; multiple versions; partial and completed adoption; interruption/restart; offline recovery; account switching and late callback rejection; device-independent cancellation; split-section and silent-entry mapping; seeks across split boundaries; underrun; codec failure visibility; and completion based on seals. Prove that adopting Broken Stars leaves its scope and published audio hashes unchanged and does not schedule replacement synthesis for already verified segments.

On a signed physical iPhone using the same Production account, discover Broken Stars without first requesting its preparation from the phone, adopt it, and play verified downloaded segments across at least two available narration sections. Validate pause/resume, restart, seek, and waiting for unavailable audio. When the book is complete, verify all parts and end-of-book, then verify access to published audio with the Mac asleep. Separately submit a new phone-originated request and verify the Mac receives it. Use disposable fixtures for disruptive recovery/cancellation tests rather than cancelling the active Broken Stars request.

Production already has the ten narration record types and fields documented in `docs/COMPANION-PRODUCTION-SCHEMA.md` and `Apps/LibroxCompanion/Validation/production-schema-2026-11-05.json`. Do not reset or recreate the schema. Prefer compatible reuse of existing records; if adoption/retention needs additional fields or types, implement an additive versioned migration and document the exact deployment requirement. Existing records and the active preparation must remain readable. The companion is locally development-certificate signed with an explicitly permitted Production entitlement; this is not an App Store release.

Use actual source signatures as authority, particularly `PreparedBookService.swift`, `CloudPreparedBookService.swift`, `BookPreparation.swift`, `BookDocument.swift`, `BookEntryContent.swift`, and the verified player integration. Deliver the iOS changes, necessary portable SDK changes, exact pinned revision, tests, and an evidence report. Distinguish local tests, signed builds, live iCloud/device playback, listening acceptance, and release status. Do not claim physical verification from a simulator or the Mac’s self-authored delivery diagnostic. If a real device/account or deployment is unavailable, finish independent implementation and state the precise remaining acceptance check. App Store/TestFlight submission remains a separate release workflow.
