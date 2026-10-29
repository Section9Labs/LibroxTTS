#!/usr/bin/env python3
"""Bounded exact CPU fallback transport; never reads model/reference outputs."""
import hashlib
import json
from pathlib import Path
import sys
import time
from operator_semantics import coefficient32, softmax32
from rope_semantics import Budget, rounded_ratio, require


def resolve(request_path, response_path):
    require(not response_path.exists(), "preserve response")
    require(0 < request_path.stat().st_size <= 64 * 1024 * 1024, "request size")
    budget = Budget(); budget.check()
    raw = request_path.read_bytes(); request = json.loads(raw)
    require(request["schema"] == 1 and isinstance(request["id"], str) and len(request["id"]) == 36,
            "request identity")
    seconds = request["remaining_seconds"]
    require(isinstance(seconds, (float, int)) and 0 < seconds <= 180, "remaining budget")
    rows = request["requests"]
    require(1 <= len(rows) <= 4096, "request count")
    total = 0; results = []
    def checked(bits, maximum):
        nonlocal total
        require(isinstance(bits, list) and 1 <= len(bits) <= maximum, "vector bound")
        total += len(bits); require(total <= 4_000_000, "aggregate operand bound")
        require(all(type(b) is int and 0 <= b <= 0xFFFFFFFF for b in bits), "F32 bit values")
        for b in bits:
            coefficient32(b)
        return bits
    for row in rows:
        budget.check(); require(time.monotonic() - budget.began <= seconds, "shared deadline")
        if row["kind"] == "softmax":
            bits = softmax32(checked(row["scores"], 1536))
        elif row["kind"] == "dot":
            x, w = checked(row["left"], 4096), checked(row["right"], 4096)
            require(len(x) == len(w) and row["output"] in ("f16", "f32"), "dot contract")
            integer = sum(coefficient32(a) * coefficient32(b) for a, b in zip(x, w))
            e, f = (5, 10) if row["output"] == "f16" else (8, 23)
            value = rounded_ratio(integer, 1 << 298, e, f)
            require((value & (0x7C00 if e == 5 else 0x7F800000)) !=
                    (0x7C00 if e == 5 else 0x7F800000), "nonfinite dot result")
            bits = [value]
        else:
            raise ValueError("unknown exact request")
        results.append(dict(kind=row["kind"], bits=bits))
    budget.check(); require(time.monotonic() - budget.began <= seconds, "shared deadline")
    response = dict(schema=1, id=request["id"], request_sha256=hashlib.sha256(raw).hexdigest(), results=results)
    # Write a unique response only after every exact request succeeds.
    response_path.write_text(json.dumps(response, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    require(len(sys.argv) == 3, "usage: reference_exact_resolver.py REQUEST RESPONSE")
    resolve(Path(sys.argv[1]), Path(sys.argv[2]))
