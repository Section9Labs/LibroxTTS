# Delivery evidence — 5 November 2026

The delivered app is a signed, local Development build. It is not a notarized distribution or an App Store/TestFlight release. iOS integration is the next consumer task described in the handoff prompt.

## Verified

- Native Release executable and app bundle build; deep/strict signature verification with the existing Companion development identity/profile.
- Regression selection: 335 tests passed (29 XCTest renderer tests, 112 Swift Testing planning/renderer tests, 191 chapter-worker tests, 3 companion import tests). The selection includes cancellation/join ownership, same-installation claim recovery, rejection of another worker's takeover, uncertain cloud commit readback, epoch invalidation, EPUB spine/silent-entry handling and exact Unicode preservation.
- Actual signed private CloudKit account/zone/directory connection: `cloud-2026-11-05.json`.
- Actual native Chatterbox model → verified file export → private CloudKit asset publication → independent reader download/custody → chapter seals and end-of-book: `delivery-2026-11-05.json`. Two self-authored English chapters produced four verified ALAC24 files. The complete check and joins took 326.22 seconds, including model cold load and network operations; this is not a synthesis speed benchmark.
- The real-file diagnostic ran in the signed Release app with separate reader and worker gates/directories. It did not share files between those roles. The reader copied its verified downloads into `/tmp/librox-companion-evidence/delivery-final/verified-<chapter>-<segment>.m4a` for local review. The first file is mono, 24 kHz, 24-bit ALAC, 40,320 valid frames.
- The native compact panel and Settings were inspected in the actual signed app. The first pass found clipped empty-state text and an AppKit termination/main-actor deadlock; both were fixed. The successful delivery diagnostic exited after its cleanup completed.
- The final app was installed at `/Applications/Librox Companion.app`, signature-verified, and its panel and Settings inspected in both light and dark appearance. Command-Q from Settings exited cleanly. Preparation was left paused. Existing login-item status was preserved.

## Scope and remaining acceptance

The first delivery attempt was interrupted before completion and is not counted as a pass. The successful report above is the second isolated run. Final lifecycle refinements serialize sleep/wake reconnection, join retained diagnostics during quit, and validate the worker-lock path's inode. Diagnostic launch also suppresses restoring the normal worker's enabled preference. There has not been a second model run solely for those refinements.

Physical iPhone submission/playback, different-machine operation, long-book endurance, real account switching during inference, listening acceptance, Spanish listening, AAC codec acceptance, and production CloudKit deployment remain unverified. Do not infer them from the successful ALAC diagnostic. The catalog deliberately retains pending listening approval. Existing raw/encoded audio validation remains unchanged, including rejection of AAC decoded overshoot.

The app requires its existing external model pack and keeps completed files under bounded disk admission. This version does not bundle/download the multi-gigabyte model, implement automatic cache eviction, or deploy CloudKit push subscriptions. Directory discovery is bounded to 64 scopes. A crashed worker may recover only with its original installation directory and exclusive lock; a different Mac does not steal claims by timeout.

The old uncommitted Libros companion worktree was inspected but not edited. Its nil factories are not the delivered runtime. This checkout's existing cloud metadata/work foundations were completed and composed into the new service and worker without replacing the native model or weakening verification guards.
