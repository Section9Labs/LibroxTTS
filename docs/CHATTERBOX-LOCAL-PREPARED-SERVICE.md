# Concrete local prepared Reader service

`ChatterboxLocalPreparedChapterService` implements every method of
`ChatterboxPreparedChapterService` against the actual Reader-owned durable
outbox, exact source/plan publications and verified audio custody. It does not
keep an app-side plan stash or synthesize a recipe from opaque hashes. The SDK
host factory supplies the actual prepared-backend catalog and transfers ownership
of the Reader journal and two separate Reader budgets. No public constructor
accepts arbitrary model identity strings.

Submit validates the complete pair against the actual catalog descriptor and
delivery support, reserves bounded source/plan growth and commits the exact
Reader intent triple only after its producers join and settle. Recovery reads
that same stored pair. Download compares the supplied plan with durable options,
observes an exact current-intent completion or retained immutable reference,
then actually copies, hashes and decodes audio under Reader storage admission
before atomic wanted-intent acceptance. Only that adopted custody becomes
playable. A metadata manifest is only `remoteReady`, including for a local Worker;
observing it does not download, submit demand or start model work.

Receipts remain `localIntent`, never invented CloudKit acknowledgement. Catalog
`deliveryDomain == .local` explicitly means the local journal is the complete
local control authority: the UI may finish a local-only cancellation after its
exact durable wanted=false receipt. The default catalog domain remains `.cloud`,
where cancellation still requires the exact real conditional server receipt.
Domain does not assert availability or listening approval. Cancel preserves
source/options/completed files and uses control-plane capacity independent of
ordinary artifact allowances. A command stamp and cancellation of older
same-request tasks prevent a submit delayed in catalog validation from restoring
cancelled demand.

Updates provide an immediate full snapshot and retain the exact local receipt
in every subsequent snapshot. There are at most 64 subscriptions and one owned
one-second observation loop per connection, only while subscribed. It checks
exact metadata identities, not a corpus/directory scan. Coalescing uses
`bufferingNewest(1)` and sequence numbers increase per subscription. Cancelling
the last subscription cancels observation; its task remains retained until
joined by close or before replacement. No work claim, rendering, download or
playback is started by subscribing. Missing submitted intent finishes with an
explicit error; corrupt evidence is not shown as idle or ready.

Ordinary calls are owned tasks (limit32); control calls retain headroom up to48.
Connection close first blocks admission, cancels and joins all exact operations
and the observer, then closes Reader stores/budgets and finishes streams. It
neither closes the independently owned Worker nor revokes a newer host account
epoch. The caller still validates its account gate after awaits before installing
any returned value. Journal state and immutable completed data survive close.

The service's package construction seam is not an activated application factory.
Native prepared-backend host assembly, authenticated cross-process descriptor
transport and real signed-host generation remain separate gates. This local
service does not perform CloudKit calls: the later cloud route must supply actual
source/audio assets, leases and server receipts rather than relabel local writes.
Tests exercise this real service, owned synthetic Worker and real AAC custody;
they do not establish production voice, cloud transfer or throughput acceptance.
