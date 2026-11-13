# Rejected or gated experiments

`capacity-storage.swift.txt` and `capacity-storage.patch` preserve the private
capacity prototype. The patch records the experiment against the pre-runtime
candidate (`144f091` has the same runtime as 0.9); it is an audit artifact, not an
automatically applicable patch against the final candidate. Public cache
constructors kept their legacy semantics throughout. The experiment passed exact
PCM but was excluded: CPU favored removing it, while GPU benefits were obscured
by large run-to-run variation. See `../runtime-decisions.md` and the three-variant
`../backend-abba.json` receipt for the tradeoff.

The flow-compilation probe lives in `Tests/PocketTTSMLXTests/FlowCompilation10Tests.swift`.
It is opt-in, records bit differences and first/warm timings, and never enables
compilation in production. Its test succeeding means the receipt was produced;
inspect `flow-compilation-experiment.json` for exactness and costs. The tested flow
outputs matched, but this is not complete-engine qualification. CPU first-use
compilation cost 156.3 seconds in the recorded run.
