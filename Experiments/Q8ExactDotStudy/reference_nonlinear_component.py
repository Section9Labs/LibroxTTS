#!/usr/bin/env python3
"""Resolve only uncertified rows, then prepare the finite-half sigmoid cache.

Consumes a fresh Swift component report. Never supplies captured expectations
as a fallback. All data is fixed public diagnostic data; no model or audio.
"""
from array import array
import hashlib
import json
from pathlib import Path
import struct
import sys
from exact_dot import SafeTensors
from operator_semantics import softmax32, sigmoid32, lift_half, multiply32
from rope_semantics import Budget, require

RAW_SHA = "233c17befb0b9f82d59e151b1bb9c72cb01b13504f5708d17b89b3eb08258fe3"
PRIMITIVE_SHA = "ba0a7add438d5f1326ce7aa541339cee4b2d3d3d973c3f56ddfb6019b00d38d4"
PREREG = "7dbcccd1c4ed328b548684b795b324ac0ca807bf03fdf59ed4bcd0b428b41d46"


def validate_report(report):
    require(report.get("completed") is True and report.get("production_clearance") is False and
            report.get("assembled_reference_clearance") is False and
            report.get("fixture_sha256") == RAW_SHA and report.get("preregistration_sha256") == PREREG and
            report.get("certified_bit_mismatches") == 0, "Swift report scope/identity")
    rows = report["rows"]
    require(len(rows) == 960 and {(r["layer"], r["head"]) for r in rows} ==
            {(layer, head) for layer in range(30) for head in range(32)}, "row membership")
    return rows


def analyze(fastpath, operator_path, primitive_path, preregistration, output, expected_fast_sha):
    require(not output.exists(), "preserve old component receipt")
    require(0 < preregistration.stat().st_size < 65536 and
            hashlib.sha256(preregistration.read_bytes()).hexdigest() == PREREG, "preregistration identity")
    budget = Budget(); budget.check()
    require(0 < fastpath.stat().st_size < 8_000_000, "fast report size")
    raw_report = fastpath.read_bytes()
    require(hashlib.sha256(raw_report).hexdigest() == expected_fast_sha, "pinned Swift report identity")
    report = json.loads(raw_report)
    rows = validate_report(report)
    operators = SafeTensors(operator_path, RAW_SHA)
    probabilities, fallback_rows, certified_rows = [], 0, 0
    for row in rows:
        budget.check()
        stem = f"tfmr.layers.{row['layer']}.attention"
        scores = operators.tensor(stem + ".scores", "F32", [2, 16, 1, 96])
        expected = operators.tensor(stem + ".probabilities", "F32", [2, 16, 1, 96])
        begin = row["head"] * 96
        bits = [v & 0xFFFFFFFF for v in scores[begin:begin + 96]]
        require(row["score_bits"] == bits, "Swift row input identity")
        if "bits" in row:
            require(row["unresolved_components"] == 0 and len(row["bits"]) == 96, "certified row contract")
            actual = row["bits"]
            certified_rows += 1
        else:
            require(1 <= row["unresolved_components"] <= 96, "unresolved row contract")
            actual = softmax32(bits)  # Independent recomputation; no expected bits used.
            fallback_rows += 1
        require(actual == [v & 0xFFFFFFFF for v in expected[begin:begin + 96]], "full softmax parity")
        probabilities.append(dict(layer=row["layer"], head=row["head"], bits=actual))
    require((certified_rows, fallback_rows) == (report["certified_rows"], report["unresolved_rows"]), "row counts")
    table = array("I", [0x7FC00000]) * 65536
    finite_count = 0
    for bits in range(65536):
        if bits % 256 == 0:
            budget.check()
        if bits & 0x7C00 == 0x7C00:
            continue
        table[bits] = sigmoid32(lift_half(bits))
        finite_count += 1
    require(finite_count == 63488, "finite half membership")
    primitive = SafeTensors(primitive_path, PRIMITIVE_SHA)
    silu_values = 0
    for layer in range(30):
        budget.check()
        stem = f"tfmr.layers.{layer}.mlp"
        gate = primitive.tensor(stem + ".gate_proj.output", "F16", [2, 1, 4096])
        up = primitive.tensor(stem + ".up_proj.output", "F16", [2, 1, 4096])
        expected = operators.tensor(stem + ".activated", "F32", [2, 1, 4096])
        for i, (g, u, target) in enumerate(zip(gate, up, expected)):
            if i % 256 == 0:
                budget.check()
            actual = multiply32(multiply32(lift_half(g), table[g]), lift_half(u))
            require(actual == target & 0xFFFFFFFF, "sigmoid lookup SiLU parity")
            silu_values += 1
    require(silu_values == 245760, "all SiLU outputs")
    if sys.byteorder != "little":
        table.byteswap()
    data = table.tobytes()
    budget.check()
    output.mkdir(exist_ok=False)
    (output / "diagnostic-f16-sigmoid-f32-v01.bin").write_bytes(data)
    (output / "resolved-softmax-bits.json").write_text(json.dumps(probabilities, separators=(",", ":")) + "\n")
    result = dict(completed=True, diagnostic_only=True, production_clearance=False, assembled_reference_clearance=False,
                  preregistration_sha256=PREREG, fastpath_report_sha256=hashlib.sha256(raw_report).hexdigest(),
                  operator_fixture_sha256=RAW_SHA, primitive_fixture_sha256=PRIMITIVE_SHA,
                  certified_softmax_rows=certified_rows, exact_fallback_rows=fallback_rows,
                  softmax_bits_bit_identical=92160, sigmoid_finite_values=finite_count,
                  sigmoid_nonfinite_sentinels=2048, sigmoid_table_bytes=len(data),
                  sigmoid_table_sha256=hashlib.sha256(data).hexdigest(), silu_bits_bit_identical=silu_values,
                  limits="Nonlinear reference components only; remaining vector operators, assembly, controls and holdouts still pending")
    budget.check()
    (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    require(len(sys.argv) == 7, "usage: reference_nonlinear_component.py FAST_REPORT OPERATOR_BITS PRIMITIVES PREREG NEW_OUTPUT FAST_REPORT_SHA")
    analyze(*(Path(p) for p in sys.argv[1:6]), sys.argv[6])
