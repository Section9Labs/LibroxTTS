# Native Mac GPU narration candidate

The opt-in native acoustic seam reuses the original Standard decoder and its
unchanged weight/oracle hashes and numerical gates. The regular S3Gen backbone,
CFM and vocoder run in Swift/MLX on GPU with full-F32 acoustic parameters. There
is no 8-bit model, second decoder, shortened solver or watermark load/application.
Backend/output policy identities are included in rendered-cache keys.

`native-full-narration-v02` on Apple M3 Ultra256GiB produced:

| Language | Actual audio | Complete warm work | Playback multiple |
| --- | ---: | ---: | ---: |
| English |13.32s|6.2513s|2.1308x|
| Spanish |16.48s|7.5348s|2.1872x|

Complete work includes planning, Standard decoding, native acoustics, cadence,
fresh cache I/O, WAV+ALAC export and decoded readback verification. Model
identity validation/loading cost141.97s separately; total cold program155.77s.
No cloud transfer was measured. These are short stock narration samples, serial
sentences, no overlap; not sustained chapter/concurrency results. User listening
approval and5x playback target remain open. No release/TestFlight is authorized.

Evidence root:
`/Volumes/T9.2025/LibroxTraining/runs/chatterbox-macos-pro-evaluation-v01/native-full-narration-v02`

Manifest SHA:65cd11258861f68b4b9251af408687a4d8da7d960a7e6c5cb98a207f14b88dff
Report SHA:5262398883b34a1aa3adeba56933ec51f2e9a5f705676c693976a2c543bd2118

The supervisor enforces360s/6GiB, memory/disk/thermal/low-power/cancellation
checks, unique explicit source binding, every frontend/optional-config identity,
fixed text/model/scheduling identities, actual distinct exported files and owned
process-group join. The V01 export failure remains immutable. Never restart a
terminal run or use a partial receipt as an accepted result.

Next work: listening review, separately bounded grouping/overlap throughput,
full-chapter assembly/source mapping, exact smaller packaging of already-used
weight dtypes, durable chapter queue and actual private-CloudKit transfer. No
additional private conditioning may be uploaded under the stock-only scope.
