#!/usr/bin/env python3
"""Stage the pinned expression generation without changing published DK assets."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Integrations/CTNative/Sources/LibroxCTNative/Resources"
IDENTITY = "librox-plus-dk-expression-round07-v1"
TAG = "plus-dk-expression-round07-v1"
BASE_TAG = "plus-dk-coreml-preview-v2"
EXPRESSION_SHA = "07166b8dbcc7de7d987e39bec031977eae8b86ca56d8c11ecb59ffe31619211e"

def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

def verify(path, file):
    if path.stat().st_size != file["bytes"] or sha(path) != file["sha256"]:
        raise ValueError("Pinned source mismatch: " + str(path))

parser = argparse.ArgumentParser()
parser.add_argument("--base", type=Path, required=True)
parser.add_argument("--graphs", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if args.output.exists():
    raise FileExistsError("Use a new output directory; staged generations are immutable")
base = json.loads((RESOURCES / "CTCoreMLManifest.json").read_text())
manifest_data = (RESOURCES / "CTExpressionManifest.json").read_bytes()
if hashlib.sha256(manifest_data).hexdigest() != EXPRESSION_SHA or (args.graphs / "manifest.json").read_bytes() != manifest_data:
    raise ValueError("Expression manifest does not match approved Round 07")
graph = json.loads(manifest_data)
additional = [{**f, "path": "expression/" + f["path"]} for f in graph["files"]]
for relative, resource in [("expression/manifest.json", "CTExpressionManifest.json"),
                           ("expression/MODIFICATIONS.md", "CTExpressionModifications.md")]:
    path = RESOURCES / resource
    additional.append(dict(path=relative, bytes=path.stat().st_size, sha256=sha(path)))
files = base["files"] + additional
known = {(f["sha256"], f["bytes"]): f for f in base["files"]}
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".stage-expression-", dir=args.output.parent) as temp:
    stage = Path(temp)
    model = stage / "model"
    public = stage / "public-release"
    public.mkdir()
    download_files = []
    new_bytes = 0
    for f in files:
        relative = f["path"]
        if relative == "expression/manifest.json":
            source = RESOURCES / "CTExpressionManifest.json"
        elif relative == "expression/MODIFICATIONS.md":
            source = RESOURCES / "CTExpressionModifications.md"
        elif relative.startswith("expression/"):
            source = args.graphs / relative.removeprefix("expression/")
        else:
            source = args.base / relative
        verify(source, f)
        target = model / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        reusable = known.get((f["sha256"], f["bytes"]))
        source_tag = BASE_TAG if reusable else TAG
        source_path = reusable["path"] if reusable else relative
        url = "https://github.com/Section9Labs/LibroxTTS/releases/download/" + source_tag + "/" + source_path.replace("/", "--")
        download_files.append(dict(path=relative, size=f["bytes"], sha256=f["sha256"], sourceURL=url))
        if not reusable:
            shutil.copy2(source, public / relative.replace("/", "--"))
            new_bytes += f["bytes"]
    for f in files:
        verify(model / f["path"], f)
    native = dict(identity=IDENTITY, referenceManifestSHA256=EXPRESSION_SHA,
                  parameterCount=base["parameterCount"], files=files)
    download = dict(repository="Section9Labs/LibroxTTS", revision=TAG,
                    files=download_files, installedFiles=download_files)
    (stage / "native-manifest.json").write_text(json.dumps(native, indent=2) + "\n")
    (public / "download-manifest.json").write_text(json.dumps(download, indent=2) + "\n")
    receipt = dict(identity=IDENTITY, releaseTag=TAG, expressionManifestSHA256=EXPRESSION_SHA,
                   installedFiles=len(files), installedBytes=sum(f["bytes"] for f in files),
                   newDownloadBytesForVerifiedDK=new_bytes, publicAttachments=len(list(public.iterdir())),
                   published=False, scope="Staged verified files only; no public activation or TestFlight claim")
    (stage / "staging-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    stage.rename(args.output)
print(json.dumps(receipt, indent=2))
