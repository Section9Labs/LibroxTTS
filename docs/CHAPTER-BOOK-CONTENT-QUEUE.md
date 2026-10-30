# Durable Reader book-entry upload material

This package-internal stage retains actual exact source/options content for
pending uploads, including the literal source of silent entries. It does not
provide authoritative cloud book controls, an inference grant or playable media.
The app does not open this journal or manage these files.

`ChatterboxLocalBookContent.persist` validates the canonical exact entry against
the prepared book, observes the Reader's current wanted/prior-entry token and
requires a dedicated managed Reader artifact root. For narrated entries it
actually receives the already-admitted source and portable plan and compares
their bytes/request to the content; a copied opaque recipe or plan reference
cannot invent a durable pair. Literal silent entries are reclassified and their
exact original text is included in the canonical immutable content envelope.

The producer reserves 16 MiB soft retained growth for the at-most8 MiB staged
and final content aliases. It publishes the existing bounded no-replace/hash-
named immutable blob, verifies staged bytes and syncs file/parent. Its exact
producer/children JOIN, then the allowance settles BEFORE the Reader atomically
attaches content identity and pending upload to the current entry. Late cancel,
re-request, close, epoch replacement or changed prior source/plan returns no
successful admission; completed immutable blobs remain intact. No eviction or
recursive cleanup occurs. Control/activation/cancel journal writes remain outside
ordinary artifact allowances; physical disk exhaustion remains fallible.

The Reader stores only content identity and optional content server revision,
not paths, handles, audio, original source text or producer epoch in its mutable
journal. Pending uploads prioritize the current original spine index and then
wrap to earlier entries without dropping front matter. After restart, actual
bounded blob read/hash/canonical/source/options checks reconstruct under the
receiver's OWN current gate. Missing/corrupt data throws; it is never inferred
from metadata or silently regenerated. This is source/options, never audio/KV.

Content identity attachment advances the book revision while preserving wanted
revision. Changing the admitted plan clears the old content identity/ack;
re-admitting the exact same pair preserves it. Content acknowledgement requires
the exact current wanted intent and identity; a late cancel/seek/re-request
callback cannot confirm. Content acknowledgement does NOT clear the device's
pending BOOK intent or become a demand acknowledgement. Cancellation preserves
all content/reference/ack material for later explicitly wanted preparation.

## Explicit book journal V2 fence

Unactivated V1 encoding remains unchanged when optional content fields are nil.
Before the content mode is used, the SDK exclusively owns the Reader role lock
and durably activates V2, including an EMPTY journal:

1. Write/sync journalV2 with the original binding. Old writers reject V2.
2. Write/sync bindingV2, preserving account/device/publisher/root identity. Old
   writers reject bindingV2 even if someone supplies an older journal.
3. Write/sync journalV2 with bindingV2. V2 is permanent for subsequent mutations.

The SDK's sole allowed binding replacement is this explicit forward activation;
it never changes the publisher or root identity. A failure poisons the live
writer. Reopen validates exact canonical checksum, root and binding, and only
finishes these two recognized V2 activation intermediate states. It never rolls
back to old wanted state. BindingV2 with journalV1, missing/corrupt established
state or a foreign binding fails closed. No old plain writer can mutate an
activated empty queue. No original user journal is opened or migrated in tests.

These are actual filesystem/restart-shaped checks, not separately signed process,
power-loss, server rollback, authenticated IPC or distributed lease proof.
Whole directory replacement/deletion across process restarts still needs an
independent host/server identity. OS-refused cleanup remains ambiguous.

## Remaining integration

The finite `ChatterboxBookContentUpload` connector now reads this queue, obtains
an actual native content receipt, joins/settles and confirms exact current
content without acknowledging the book; see `CHAPTER-BOOK-CONTENT-UPLOAD.md`.
A real Reader service must own/cancel/join its calling tasks and replay this
state before publishing authoritative whole-book cloud controls. Current-intent
transactions, authenticated prepared catalog, Worker generations/claims/clock-
lease policy, ordered segment heads/seals, actual current-book audio acceptance
and separate-host factories/runtime qualification are unfinished. This component
does not activate a provider or call CloudKit, models, apps or phones.
