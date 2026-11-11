#!/usr/bin/env python3
"""Verify planning fingerprints and compare the identical synthetic workloads."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()

def rows(path):
    return {(r["model"], r["inputScalars"]): r for r in json.loads(path.read_text())}

old, new = rows(a.baseline), rows(a.candidate)
assert old and old.keys() == new.keys(), "Missing or extra workloads"
paired = []
for key in sorted(old):
    x, y = old[key], new[key]
    assert x["planSHA256"] == y["planSHA256"] and x["units"] == y["units"], key
    paired.append(dict(model=key[0], inputScalars=key[1], units=x["units"],
        planSHA256=x["planSHA256"], baselineSeconds=x["medianSeconds"],
        candidateSeconds=y["medianSeconds"], speedup=x["medianSeconds"] / y["medianSeconds"]))
report = dict(exactPlanFingerprints=True, rows=paired,
    scope="Spanish repeated-clause source planning; three-run medians; no model inference",
    limitations=["Shared workstation, not a device or representative book benchmark",
                 "Fingerprints cover ranges, voices and synthesis text; the separate golden suite covers other plan fields"])
a.output.write_text(json.dumps(report, indent=2) + "\n")
for row in paired:
    print(f'{row["model"]} {row["inputScalars"]}: {row["baselineSeconds"]:.6f}s -> '
          f'{row["candidateSeconds"]:.6f}s ({row["speedup"]:.2f}x)')
