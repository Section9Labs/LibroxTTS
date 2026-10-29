# Isolated Q8 cache diagnostic

Local developer harness only, bundle `com.librox.ChatterboxBenchmark`; version
and build come from `project.yml`. It does not update Librox, access its container, load voice recordings,
produce audio or change the production accuracy gate. It uses the SDK's reviewed
fixed-fixture diagnostic rather than implementing model math in an app.

Generate this Xcode project from `project.yml`. Use an isolated DerivedData
directory, Release configuration and `-skipPackagePluginValidation`. Coordinate
the source/build/device ownership with MAIN. Do not install or launch until Matt
confirms current availability for the frozen signed artifact.

The foreground harness waits at most90seconds for an operator request while
holding only its app-scoped idle timer. Backgrounding cancels and joins the SDK
worker; completion restores the idle timer. No background inference or retry.

After an authorized install-over of the old benchmark bundle, launch the harness
and copy these public artifacts into its container:

`Documents/q8-cache-replay-v01/inputs/`

- `backbone-q8-g64-f16scales.safetensors`
- `q8-dense-cpu-reference-v01.safetensors`
- `cpu-es-prefill-kv-v01.safetensors`

Copy `Documents/q8-cache-replay-v01/request.json` **last**. It must contain a new
UUID `runID`, `expiresAt` (Unix seconds, no more than180seconds ahead), and the
exact `sdkRevision` from `project.yml`. The SDK verifies all artifact identities.
Each received request is atomically retired into its unique launch directory,
including malformed/expired requests. A valid request is consumed once before
model work; no automatic retry.

Read `Documents/q8-cache-replay-v01/latest-status.json`, then
`Documents/q8-cache-replay-v01/runs/<runID>/report.json`. Each launch and accepted
run retains its own status/error receipt; a later launch cannot overwrite old
terminal evidence. Results contain fixed
public-fixture comparisons only. Keep all previous benchmark data and reports.
After results are captured and the worker is finished, terminate only this owned
benchmark process and release the phone reservation. No release or TestFlight.
