#!/usr/bin/env python3
"""Compare macOS public declarations with the frozen 0.6.2 inventory.

Run swift package dump-symbol-graph --minimum-access-level public
--skip-synthesized-members first. This supplements client/behavior tests; it
does not establish binary ABI or platform-specific iOS compatibility.
"""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--graphs", type=Path, default=Path(".build/out/symbolgraph"))
parser.add_argument("--baseline", type=Path, default=Path("docs/architecture-07/api-baseline.json"))
parser.add_argument("--additions", type=Path, help="Reviewed additive declarations; existing baseline remains frozen")
args = parser.parse_args()
def canonical(row):
    # Availability is a set of platform clauses. Symbol-graph emitters may
    # reorder them across Swift versions; every clause and field still matters.
    return dict(row, availability=sorted(row["availability"], key=lambda item: json.dumps(item, sort_keys=True)))

old = json.loads(args.baseline.read_text())
key = lambda row: (row["module"], row["usr"])
expected = {key(row): canonical(row) for row in old["symbols"]}
if args.additions:
    for row in json.loads(args.additions.read_text())["symbols"]:
        if key(row) in expected:
            raise SystemExit("Additions must not override frozen declarations")
        expected[key(row)] = canonical(row)
actual = {}
for path in args.graphs.glob("*.json"):
    graph = json.loads(path.read_text())
    for symbol in graph["symbols"]:
        if symbol.get("accessLevel") not in ("public", "open"):
            continue
        row = {
            "module": graph["module"]["name"], "usr": symbol["identifier"]["precise"],
            "path": symbol.get("pathComponents"),
            "declaration": "".join(f["spelling"] for f in symbol.get("declarationFragments", [])),
            "availability": symbol.get("availability", []),
        }
        actual[key(row)] = canonical(row)
missing = sorted(expected.keys() - actual.keys())
added = sorted(actual.keys() - expected.keys())
changed = sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k])
for label, values in [("missing", missing), ("added", added), ("changed", changed)]:
    for module, usr in values:
        print(f"{label}: {module} {usr}")
for item in changed[:5]:
    for field in expected[item]:
        if expected[item][field] != actual[item][field]:
            print(f"  {item[0]} {item[1]} {field}: expected={json.dumps(expected[item][field], sort_keys=True)} actual={json.dumps(actual[item][field], sort_keys=True)}")
print(f"{len(expected)} baseline entries; {len(actual)} current; "
      f"{len(missing)} missing, {len(added)} added, {len(changed)} changed")
raise SystemExit(bool(missing or added or changed))
