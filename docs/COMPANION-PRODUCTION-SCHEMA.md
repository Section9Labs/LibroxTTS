# Companion narration schema deployment

The existing Production Librox library is readable without any schema changes. The live signed check on 2026-11-05 found 51 books and verified an original EPUB against its synced content hash. Before the user deployed the schema, the read-only narration schema probe returned `Unknown Item: Did not find record type: LibroxStockCatalogV1`.

The following is the exact schema required by the delivered whole-book pipeline, derived from its native CloudKit transports. Compare it with a current Development export and the Console's deployment preview before promoting. This is an additions manifest, **not a replacement schema**. Do not reset either environment or import a partial schema as the complete container schema.

| Record type | Fields |
| --- | --- |
| `LibroxBookDirectoryV1` | `payloadV1: BYTES`, `fenceV1: STRING` |
| `LibroxStockCatalogV1` | `payloadV1: BYTES`, `fenceV1: STRING` |
| `LibroxBookDemandV1` | `payloadV1: BYTES`, `fenceV1: STRING`, `accountV1: STRING`, `scopeV1: STRING` |
| `LibroxBookDeviceV1` | `payloadV1: BYTES`, `fenceV1: STRING` |
| `LibroxBookWorkerClaimV1` | `payloadV1: BYTES`, `fenceV1: STRING` |
| `LibroxBookSegmentHeadV1` | `payloadV1: BYTES`, `fenceV1: STRING` |
| `LibroxBookSegmentIndexV1` | `payloadV1: BYTES`, `fenceV1: STRING` |
| `LibroxBookEntryV1` | `manifestV1: BYTES`, `contentV1: ASSET` |
| `LibroxBookReadSetV1` | `manifestV1: BYTES`, `contentV1: ASSET` |
| `LibroxChapterSegmentV1` | `manifestV1: BYTES`, `audioV1: ASSET` |

All runtime records use the user's **private database**, custom zone `LibroxProChaptersV1`, in `iCloud.com.section9labs.Libros`. Records are fetched by deterministic ID; no new query indexes are required for narration. Keep normal owner-private access. No changes to `CD_StoredBook`, other SwiftData records, the existing library zone, sharing configuration, original book files or reading positions are needed.

Failure status uses an independently keyed and validated metadata payload under `LibroxBookDirectoryV1`; it does not require a separate failure record type. The final pipeline requires ten record types.

Production promotion is additive and irreversible. The CloudKit Console deployment preview is the authority for its actual scope. Do not approve unrelated pending schema changes as part of this companion update. After promotion, rerun the schema check, enable the native worker, and validate a selected real-library book request. Physical iOS submission/playback remains a separate integration check.

The user signed in and deployed the pending schema changes on 2026-11-05. The Console then showed no pending changes, and the live Production catalog-type probe changed from missing type to an index-only query error. The narration protocol reads by ID and does not need that query index. The app recognizes this result as schema present. The failure-status payload uses the already-deployed directory record type. No library-schema edits were made by this task.
