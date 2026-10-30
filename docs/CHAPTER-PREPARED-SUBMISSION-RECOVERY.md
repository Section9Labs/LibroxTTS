# Exact prepared-pair recovery

`ChatterboxLocalPreparedSubmission.recover` implements the read-only durable
source/options recovery used by the prepared service contract. The Reader owns
the outbox and supplies its current account session. Explicit durable Reader
authority is required; the Worker never opens that mutable journal.

Recovery observes the stored source and plan references together, receives the
exact Unicode source under the Reader's own current epoch, and verifies the
canonical portable plan against that source and request. All authored Float32
bits, UInt64 seed, direction, grouping, delivery and nil-versus-empty annotations
come from the verified plan. No default is reconstructed from recipe hashes and
no app-maintained options stash is needed. The owned source/plan task and each
file child are cancelled and joined before return; the final Reader journal
snapshot and session are checked again.

Only an absent or incomplete stored pair returns `nil`. Missing or corrupt
referenced files, symlinks, closed or changed Reader state, wrong account and
revoked epochs throw. Recovery never silently substitutes new options, invokes
the model, publishes demand, acknowledges a server or adopts audio. It performs
bounded reads using the existing source/plan custody components and writes no
artifacts, so no new storage allowance is introduced.

A cancelled intent can retain its exact pair for UI recovery. Returning that
pair does not change wanted state or authorize rendering. A concurrent changed
intent invalidates the in-flight journal observation. As with other read-only
metadata, a later command may follow the last observation; submit and download
still require their own current-intent and epoch admission. This is not an
atomic work claim, a stock catalog or evidence of a qualified backend.

The concrete Reader service, subscriptions, actual prepared-backend catalog and
authenticated local transport/factory remain subsequent work. This component
does not activate a host or change LocalReview353. Tests use existing synthetic
metadata and real private source/plan files, without production model forwards,
cloud calls or application launches.
