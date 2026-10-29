#!/usr/bin/env python3
"""Fail-closed four-arm diagnostic controls. Stdlib only; never writes an oracle."""
import hashlib
import json
import math
import pathlib
import struct
import sys

ARMS = ("nativePrefillNativeRoPE", "densePrefillNativeRoPE",
        "nativePrefillHalfRoPE", "densePrefillHalfRoPE")
PREREG = "db069845ed6b59943481c7affa1d7e67d70e829e52f3b49e5a3d3431e40f84e6"
HISTORICAL = "2d3805667e6daee6801f2fcdfea6a0a98c57bc62255fc70d27628f1de379c872"
CERTIFIED = "e0428ba766d0ae0fc964660b3198db4d1ba4511eecdfcb7e93e12c6e9fc0ea7e"
KEYS = {f"native.{lang}.{step}" for lang in ("en", "es")
        for step in ("prefill", *(f"decode.{i}" for i in range(8)))}
KEYS |= {f"cpu93.es.decode.{i}" for i in range(3)} | {"cpu95.es.decode.2"}


def require(value, message):
    if not value:
        raise ValueError(message)


def tensors(path):
    require(path.stat().st_size < 2_000_000, "oversized logit artifact")
    data = path.read_bytes()
    require(len(data) >= 8, "short artifact")
    length, = struct.unpack_from("<Q", data)
    require(0 < length < len(data) - 8, "header length")
    header = json.loads(data[8:8 + length])
    payload = memoryview(data)[8 + length:]
    result, intervals = {}, []
    for key, spec in header.items():
        if key == "__metadata__":
            continue
        require(spec["dtype"] == "F32" and spec["shape"] == [2, 8194], "logit shape/dtype")
        start, end = spec["data_offsets"]
        require(0 <= start < end <= len(payload) and end - start == 65552, "offset bounds")
        values = bytes(payload[start:end])
        require(all(math.isfinite(x) for x in struct.unpack("<16388f", values)), "nonfinite logits")
        intervals.append((start, end))
        result[key] = values
    require(set(result) == KEYS, "condition key mismatch")
    intervals.sort()
    require(intervals[0][0] == 0 and intervals[-1][1] == len(payload)
            and all(a[1] == b[0] for a, b in zip(intervals, intervals[1:])), "payload gaps/overlaps")
    return result, hashlib.sha256(data).hexdigest()


def restored_controls(raw):
    results = {}
    for left, right in ((ARMS[0], ARMS[1]), (ARMS[2], ARMS[3])):
        for key in sorted(k for k in KEYS if k.startswith("cpu")):
            results[f"{left}/{right}:{key}"] = raw[left][key] == raw[right][key]
    require(all(results.values()), "prefill-inactive restored control failed; causal interpretation forbidden")
    return results


def validate_historical(old):
    require(old["name"] == "unchangedV2", "historical baseline identity")
    native = {k.removeprefix("native.") for k in KEYS if k.startswith("native.")}
    require(len(old["full18"]) == 18 and {r["stem"] for r in old["full18"]} == native,
            "historical native membership")
    for name, steps in (("cpu_prefill_replay", {f"es.decode.{i}" for i in range(3)}),
                        ("cpu_offset95_target", {"es.decode.2"})):
        require(len(old[name]) == len(steps) and {r["stage"] for r in old[name]} == steps,
                "historical restored membership")
        require(all(len(r["lanes"]) == 2 for r in old[name]), "historical lanes")


def validate_arm_report(report, arm):
    require(report.get("completed") is True and report.get("production_clearance") is False
            and report.get("gpu_only_model_forward") is True and report.get("arm") == arm
            and report.get("preregistration_sha256") == PREREG
            and report.get("certified_diagnostic_sha256") == CERTIFIED, "arm completion/identity")
    require(len(report["comparisons"]) == 22 and
            {r["condition"] for r in report["comparisons"]} == KEYS, "report keys")
    require(all(len(r[ref]["lanes"]) == 2 for r in report["comparisons"]
                for ref in ("old_oracle", "certified_diagnostic")), "report lanes")


def analyze(root, historical):
    raw, reports = {}, {}
    for arm in ARMS:
        directory = root / arm
        report = json.loads((directory / "report.json").read_text())
        validate_arm_report(report, arm)
        raw[arm], digest = tensors(directory / "diagnostic-logits.safetensors")
        require(digest == report["raw_logits_sha256"], "logit hash")
        reports[arm] = report
    require(len({r["pid"] for r in reports.values()}) == 4, "fresh-process control")
    controls = restored_controls(raw)
    history = historical.read_bytes()
    require(hashlib.sha256(history).hexdigest() == HISTORICAL, "historical artifact hash")
    old = json.loads(history)["arms"][0]
    validate_historical(old)
    baseline = {r["condition"]: r["old_oracle"] for r in reports[ARMS[0]]["comparisons"]}
    # Exact float32/maxabs and gate agreement; rounded serialized lane margins
    # must round back to the identical binary32 value. RelativeL2 retained too.
    def same_float(a, b):
        return struct.pack("<f", a) == struct.pack("<f", b)
    for entry in old["full18"]:
        got = baseline["native." + entry["stem"]]
        require(same_float(got["maximumAbsoluteError"], entry["max_abs"])
                and got["relativeL2"] == entry["relative_l2"]
                and got["passesOriginalCriteria"] == entry["production_gate_passed"], "native legacy reproduction")
    for offset, entries in ((93, old["cpu_prefill_replay"]), (95, old["cpu_offset95_target"])):
        for entry in entries:
            got = baseline[f"cpu{offset}." + entry["stage"]]
            require(same_float(got["maximumAbsoluteError"], entry["maximumAbsoluteError"])
                    and got["relativeL2"] == entry["relativeL2"]
                    and got["passesOriginalCriteria"] == entry["passesOriginalCriteria"], "restored legacy reproduction")
            for a, b in zip(got["lanes"], entry["lanes"]):
                require(a["actualTopID"] == b["actualTopID"] and same_float(
                    a["actualMarginBetweenExpectedLeaders"], b["actualMarginBetweenExpectedLeaders"]), "legacy lane reproduction")
    return {"completed": True, "diagnostic_only": True, "production_clearance": False,
            "legacy_baseline_reproduced": True, "prefill_inactive_restored_controls": controls,
            "arms": reports, "scope": "Policy factors only; no app oracle, quality, phone or speed acceptance"}


if __name__ == "__main__":
    require(len(sys.argv) == 3, "usage: gpu_factor_controls.py RUN_ROOT HISTORICAL_REPORT")
    result = analyze(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    output = pathlib.Path(sys.argv[1]) / "controls-report.json"
    require(not output.exists(), "preserve previous report")
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
