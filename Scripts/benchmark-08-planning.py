#!/usr/bin/env python3
"""Pair identical PlanningBaseline probes in ABBA order; require exact fingerprints."""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--scope", default="Spanish repeated-clause source planning; three samples per process; two processes per revision")
a = p.parse_args()
runs = []
for revision in ["baseline", "candidate", "candidate", "baseline"]:
    binary = getattr(a, revision).resolve()
    rows = json.loads(subprocess.check_output([str(binary)], text=True))
    runs.append({"revision": revision, "rows": rows})
    print(f"Completed {revision}", flush=True)

keys = {(r["model"], r["inputScalars"]) for r in runs[0]["rows"]}
assert all({(r["model"], r["inputScalars"]) for r in run["rows"]} == keys for run in runs), "Different workloads"
summary = []
for key in sorted(keys):
    rows = [next(r for r in run["rows"] if (r["model"], r["inputScalars"]) == key) for run in runs]
    assert len({(r["planSHA256"], r["units"]) for r in rows}) == 1, key
    old = statistics.median([rows[0]["medianSeconds"], rows[3]["medianSeconds"]])
    new = statistics.median([rows[1]["medianSeconds"], rows[2]["medianSeconds"]])
    summary.append(dict(model=key[0], inputScalars=key[1], units=rows[0]["units"],
                        planSHA256=rows[0]["planSHA256"], baselineSeconds=old,
                        candidateSeconds=new, speedup=old / new))
    print(f"{key}: {old:.6f}s -> {new:.6f}s ({old / new:.2f}x)")

report = dict(exactPlanFingerprints=True, order="ABBA", runs=runs, rows=summary,
    machine=platform.machine(), os=platform.platform(),
    binarySHA256={name: hashlib.sha256(getattr(a, name).read_bytes()).hexdigest()
                  for name in ["baseline", "candidate"]},
    scope=a.scope,
    limitations=["Synthetic long-sentence workload on a shared Mac; not a representative book or device benchmark",
                 "Fingerprints cover ranges, voice IDs and synthesis text; separate differential tests compare complete plans"])
a.output.write_text(json.dumps(report, indent=2) + "\n")
