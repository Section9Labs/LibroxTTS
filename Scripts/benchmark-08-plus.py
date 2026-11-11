#!/usr/bin/env python3
"""Compile both CT revisions with identical flags, then run warmed ABBA blocks.

Uses unchanged KokoroCatalog objects/resources from a built 0.7 package.
No model downloads or source mutations. Each process verifies exact baseline PCM.
"""
import argparse
import json
import statistics
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("--products", type=Path, required=True)
p.add_argument("--assets", type=Path, required=True)
p.add_argument("--audio", type=Path, required=True)
p.add_argument("--work", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
probe = Path(__file__).resolve().parents[1] / "docs/architecture-08/PlusBenchmark.swift"
flags = ["-O", "-whole-module-optimization", "-swift-version", "6", "-target", "arm64-apple-macosx15.0"]
for name, repo in [("baseline", a.baseline), ("candidate", a.candidate)]:
    work = a.work / name
    work.mkdir(parents=True, exist_ok=True)
    bundle = a.products / "LibroxTTS_LibroxCTNative.bundle"
    accessor = work / "Resources.swift"
    accessor.write_text('import Foundation\nextension Bundle { static let module = Bundle(path: '
                        + json.dumps(str(bundle)) + ')! }\n')
    sources = sorted((repo / "Integrations/CTNative/Sources/LibroxCTNative").glob("*.swift"))
    subprocess.run(["swiftc", *flags, "-parse-as-library", "-module-name", "LibroxCTNative",
        "-I", str(a.products), "-emit-object", "-emit-module", "-emit-module-path", str(work / "LibroxCTNative.swiftmodule"),
        *map(str, sources), str(accessor), "-o", str(work / "LibroxCTNative.o")], check=True)
    subprocess.run(["swiftc", *flags, "-parse-as-library", "-I", str(work), "-I", str(a.products), str(probe),
        str(work / "LibroxCTNative.o"), str(a.products / "KokoroCatalog.o"), "-o", str(work / "probe")], check=True)
    catalog = work / "LibroxTTS_KokoroCatalog.bundle"
    if not catalog.exists(): catalog.symlink_to(a.products / catalog.name)

order = ["baseline", "candidate", "candidate", "baseline"] * 2
runs = []
for index, name in enumerate(order):
    output = a.work / f"run-{index}-{name}.json"
    subprocess.run([str(a.work / name / "probe"), str(a.assets), str(a.audio), str(output)], check=True)
    rows = json.loads(output.read_text())
    runs.append(dict(index=index, revision=name, rows=rows))
    print(f"Finished {index + 1}/{len(order)}: {name}", flush=True)
summary = {}
for language in ["en", "es"]:
    groups = {name: [statistics.median(r["seconds"] for r in run["rows"] if r["language"] == language)
                     for run in runs if run["revision"] == name] for name in ["baseline", "candidate"]}
    summary[language] = dict(processMedians=groups,
        speedup=statistics.median(groups["baseline"]) / statistics.median(groups["candidate"]))
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(dict(order=order, summary=summary, exactPCM=True, runs=runs,
    scope="Direct Plus CPU synthesis, en/es, two warmups and four trials per language per process",
    limitations=["Shared Mac; no device/energy/RSS qualification", "Source-compiled CT modules using identical flags and unchanged catalog objects"]), indent=2) + "\n")
print(json.dumps(summary, indent=2))
