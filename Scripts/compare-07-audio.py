#!/usr/bin/env python3
"""Check exact PCM/events and summarize paired local Release07AudioTests receipts."""
import argparse
import hashlib
import json
import statistics
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()

def rows(root):
    return {d["name"]: d for path in root.glob("*.json")
            if isinstance(d := json.loads(path.read_text()), dict) and "name" in d}

old, new = rows(a.baseline), rows(a.candidate)
assert old and old.keys() == new.keys(), "Missing or extra trial receipts"
paired = []
for name in sorted(old):
    x, y = old[name], new[name]
    before = (a.baseline / (name + ".f32")).read_bytes()
    after = (a.candidate / (name + ".f32")).read_bytes()
    assert before == after, f"PCM changed: {name}"
    assert hashlib.sha256(before).hexdigest() == x["sha256"] == y["sha256"], name
    assert x["samples"] == y["samples"] and x["events"] == y["events"], name
    paired.append(dict(name=name, samples=x["samples"], sha256=x["sha256"],
        baselineSeconds=x["seconds"], candidateSeconds=y["seconds"],
        baselineFirstFrameSeconds=x["firstFrameSeconds"], candidateFirstFrameSeconds=y["firstFrameSeconds"],
        speedup=x["seconds"] / y["seconds"]))

summary = {}
for prefix in ["pocket-en", "pocket-es", "plus-en", "plus-es"]:
    group = [r for r in paired if r["name"].startswith(prefix)
             and "recovered" not in r["name"] and not r["name"].startswith(prefix + "-0-")]
    if group:
        before = sum(r["baselineSeconds"] for r in group)
        after = sum(r["candidateSeconds"] for r in group)
        summary[prefix] = dict(trials=len(group), baselineSeconds=before, candidateSeconds=after,
                               aggregateSpeedup=before/after,
                               medianPairedSpeedup=statistics.median(r["speedup"] for r in group))
report = dict(exactPCM=True, exactChunkEvents=True, trials=len(paired), groups=summary, rows=paired,
    limitations=["Shared workstation; one observation per paired request, not a confidence interval",
                 "Pocket first language load and cancellation/reload excluded from warm group totals",
                 "Different sampler counts and voices are distinct workloads, not repetitions",
                 "No physical-device, listening, thermal or energy qualification"])
a.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k:v for k,v in report.items() if k != "rows"}, indent=2))
