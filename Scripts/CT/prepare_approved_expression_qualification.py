#!/usr/bin/env python3
"""Copy immutable approved Round 07 replay inputs; never modify the reference."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument("reference", type=Path, help="Frozen round07-v1 artifact directory")
parser.add_argument("output", type=Path, help="New Fixtures directory")
args = parser.parse_args()
expected = {
    "source-receipt.json": "4b81a8bb743fc9ae89cef19c85351505d10dc7b1f05ed12afcf5f0f78473bfcb",
    "audio-manifest.json": "2b7c77f6377b61039073753343c2ac140a271c1f2542751c8ebb4c113b067698",
    "graphs/manifest.json": "07166b8dbcc7de7d987e39bec031977eae8b86ca56d8c11ecb59ffe31619211e",
}
for name, digest in expected.items():
    if hashlib.sha256((args.reference / name).read_bytes()).hexdigest() != digest:
        raise ValueError("Frozen reference changed: " + name)
args.output.mkdir(parents=True, exist_ok=False)
rows = []
for case in json.loads((args.reference / "cases.json").read_text()):
    directory = args.reference / "native" / case["case"] / "candidate"
    if case["kind"] == "preflight-only":
        continue
    receipt = json.loads((directory / "receipt.json").read_text())
    source = Path(case["path"]).read_bytes()
    if hashlib.sha256(source).hexdigest() != receipt["sourceSHA256"]:
        raise ValueError("Frozen passage changed: " + case["case"])
    target = args.output / case["case"]
    target.mkdir()
    for path in list(directory.glob("noise-*.bin")) + [directory / name for name in
            ["cast.json", "role-evidence.json", "reporting-evidence.json"]]:
        shutil.copy2(path, target / path.name)
    rows.append(dict(id=case["case"], text=source.decode(), language=case["language"],
                     narratorVoice=case["narratorVoice"], records=receipt["records"]))
if len(rows) != 14 or sum(len(row["records"]) for row in rows) != 55:
    raise ValueError("Incomplete approved corpus")
(args.output / "cases.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
print("Prepared 14 cases, 55 complete units")
