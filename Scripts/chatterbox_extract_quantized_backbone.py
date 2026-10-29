#!/usr/bin/env python3
"""Extract packed T3 arrays without executing repository model code.

The smdesai checkpoint's frontend differs from our V3 assets. This extractor
does not establish runtime compatibility; its output is for oracle-only audit.
"""
import argparse
import hashlib
import json
import pathlib
import struct

SOURCE_SHA256 = "54ec7ec9738d247867c63fcee7fc2d4976764045d5381bf5264afb7309eef38c"
SOURCE_REVISION = "79c221c69773d0aee69bf66f276c1fb7677e0b41"


def extract(source: pathlib.Path, destination: pathlib.Path):
    with source.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != SOURCE_SHA256:
            raise ValueError("Unexpected source checkpoint")
        stream.seek(0)
        header_size = struct.unpack("<Q", stream.read(8))[0]
        if header_size > 2_000_000:
            raise ValueError("Unbounded header")
        header = json.loads(stream.read(header_size))
        selected = {}
        for key, value in header.items():
            if key.startswith("t3.tfmr.model.layers.") or key in (
                "t3.tfmr.model.norm.weight", "t3.speech_head.weight"
            ):
                selected[key.replace("t3.tfmr.model.", "tfmr.").removeprefix("t3.")] = value
        if len(selected) != 692:
            raise ValueError("Unexpected backbone structure")
        output_header = {}
        offset = 0
        for key, value in selected.items():
            start, end = value["data_offsets"]
            if not 0 <= start <= end <= source.stat().st_size - 8 - header_size:
                raise ValueError("Invalid tensor range")
            output_header[key] = dict(value, data_offsets=[offset, offset + end - start])
            offset += end - start
        encoded = json.dumps(output_header, separators=(",", ":")).encode()
        encoded += b" " * (-len(encoded) % 8)
        # Exclusive creation preserves any previous result.
        with destination.open("xb") as output:
            output.write(struct.pack("<Q", len(encoded)))
            output.write(encoded)
            for value in selected.values():
                start, end = value["data_offsets"]
                stream.seek(8 + header_size + start)
                remaining = end - start
                while remaining:
                    chunk = stream.read(min(remaining, 1_048_576))
                    if not chunk:
                        raise ValueError("Truncated source")
                    output.write(chunk)
                    remaining -= len(chunk)
    with destination.open("rb") as output:
        checksum = hashlib.file_digest(output, "sha256").hexdigest()
    print(json.dumps({"source_revision": SOURCE_REVISION, "source_sha256": SOURCE_SHA256,
                      "extracted_sha256": checksum, "bytes": destination.stat().st_size,
                      "scope": "foreign-checkpoint oracle audit only"}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    arguments = parser.parse_args()
    extract(arguments.source, arguments.destination)
