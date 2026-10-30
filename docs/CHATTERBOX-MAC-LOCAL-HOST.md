# Native Worker host and Reader construction

The native Companion uses `ChatterboxMacLocalWorkerHost.open` with its authorized
six model assets, distinct Worker UUID/current session/gate, Worker directory
roles, a read-only authoritative demand endpoint and explicit storage policy.
Cold construction opens private Worker state/budgets but does not initialize a
model. `start()` owns actual preparation before catalog access. It obtains the
descriptor from that prepared backend; it never manufactures hashes from an
installed-files flag.

Pending listening approval permits preparation only: Supervisor claims remain
disabled and no queue driver starts, even if there are existing wanted chapters.
Rejected approval refuses start. Only approved policy enables the driver.
Approval is an explicit host/operator policy, never inferred from a signature,
successful render or encoding approval. A separately authorized bounded audition
uses the existing resident renderer API without production queue claims; see
the Alice review asset/grant handoff. No such runtime is launched by these tests.

The driver observes bounded authoritative snapshots, renders one chapter at a
time through the existing supervised full-quality pipeline and publishes exact
completion metadata. A bounded handled set is intersected with current wanted
identities; unchanged completed/failed intents do not start new generations.
Changed intent may verify/reuse existing complete audio through the original
custody path. Missing/blocked authority is waiting, not an empty queue. Source
errors or numerical/output failures do not silently fall back or repeatedly run
the same input. Failed attempts require an explicit changed intent. Active
request, wanted count, actual Worker phase and last failure are exposed as
observations, not fabricated percent progress or accepted Reader playback.
Healthy busy rendering remains queue-admissible; it does not permit a second
concurrent claim. Closed admission after a storage-settlement failure ends the
driver and invalidates catalog availability. Pair construction validates the
combined Reader/Worker role graph, permitting only the exact shared immutable
source, plan and publication roots; control and artifact ancestors cannot alias.

`stopClaims()` is synchronous and signals start/driver/Supervisor cancellation in
the host event turn. Disable joins those exact tasks before the Supervisor's
join barrier; it preserves the resident model and all queued/completed data.
Terminal shutdown joins before releasing the model/runtime, journal and budget.
The adapter must not repeat the Worker's already-completed journal relinquish.
Startup failure and cancelled cold-open clean up the roles they actually own.

The Reader remains on `LibroxChatterboxPlanning` and opens its own
`ChatterboxLocalPreparedChapterService` with six disjoint private Reader/read-only
publication roots, Reader UUID/current session/gate and two Reader storage
policies. It supplies the SDK catalog endpoint from an authorized native/cloud
connection. `localIntentDescriptor` exposes only immutable routing metadata;
the Worker never receives the mutable outbox. That descriptor is not by itself
an authenticated cross-process credential.

`ChatterboxMacLocalServicePair` assembles these two owners in ONE process for
local qualification. It is not the shipping Catalyst/iOS-to-Companion bridge;
the Reader must not import the native renderer or run a second production Reader
inside Companion. Actual authenticated IPC/CloudKit catalog, control, source and
complete audio transfer remain separate integration work. No local read/write is
relabelled an iCloud transfer. Separate signed processes, App Group authorization,
actual account/container/environment and live asset/lease acceptance are not
established by same-process tests.

GPU runtime ownership is exclusive to the dedicated native model process.
Initialize no other MLX runtime first. The app's OS asset-authorization scope must
remain valid until the SDK terminal join completes. All existing full-quality
weights, 18 startup decoder gates, frontend pins, solver/precision, finite sample,
resource and codec guards remain unchanged. Source tests use synthetic backends
and real AAC custody; actual full-chapter generation/quality/speed requires a
separate MAIN-approved signed host and resource reservation.
