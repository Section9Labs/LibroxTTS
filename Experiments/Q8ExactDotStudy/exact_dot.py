#!/usr/bin/env python3
"""Independent integer arithmetic on the preregistered public FP16 samples.

No MLX, model execution, audio, reference mutation or candidate selection.
"""
import argparse
import array
import bisect
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import time

PREREG_SHA = "78989cdfc90d052a8b196208c24b94138985118d076d59811480ca9100c5a059"
CPU_SHA = "4e7888d2af62f91037b82ad4ea24b44c3f5475305eafb5ff813fb788d87d28b7"
GPU_SHA = "2f32ce1860d4e8124c6721628f1d945eb1bc3a8b7f37c7cf516639ecef3c1c6c"


def coefficient(bits):
    """Exact signed integer coefficient in units of 2^-24; reject nonfinite."""
    exponent = (bits >> 10) & 31
    if exponent == 31:
        raise ValueError("nonfinite half operand")
    mantissa = bits & 1023
    value = mantissa if exponent == 0 else (1024 + mantissa) << (exponent - 1)
    return -value if bits & 0x8000 else value


def round_half(integer_product_units):
    """Round integer * 2^-48 once to binary16, nearest/ties-to-even."""
    if integer_product_units == 0:
        return 0
    sign = 0x8000 if integer_product_units < 0 else 0
    magnitude = abs(integer_product_units)
    shift = max(24, magnitude.bit_length() - 11)
    quotient, remainder = divmod(magnitude, 1 << shift)
    midpoint = 1 << (shift - 1)
    if remainder > midpoint or (remainder == midpoint and quotient & 1):
        quotient += 1
    half_units = (quotient << shift) >> 24
    if half_units < 1024:
        return sign | half_units
    exponent = half_units.bit_length() - 10
    if exponent >= 31:
        return sign | 0x7C00
    mantissa = (half_units >> (exponent - 1)) - 1024
    return sign | (exponent << 10) | mantissa


def zero(bits):
    return bits & 0x7FFF == 0


def equal(a, b):
    return a == b or (zero(a) and zero(b))


def ulps(a, b):
    if equal(a, b):
        return 0
    def ordered(bits):
        return -(bits & 0x7FFF) if bits & 0x8000 else bits
    return abs(ordered(a) - ordered(b))


def self_test():
    if not __debug__:
        raise RuntimeError("rounding validation requires Python assertions enabled")
    # Independent nearest-neighbour search over all finite positive half values.
    representable = [coefficient(b) << 24 for b in range(0x7C00)]
    overflow = 65520 << 48
    def neighbour_round(value):
        sign = 0x8000 if value < 0 else 0
        magnitude = abs(value)
        if magnitude >= overflow:
            return sign | 0x7C00
        upper = bisect.bisect_left(representable, magnitude)
        if upper == 0:
            chosen = 0
        elif upper == len(representable):
            chosen = upper - 1
        else:
            low_distance = magnitude - representable[upper - 1]
            high_distance = representable[upper] - magnitude
            chosen = upper - 1 if low_distance < high_distance else upper
            if low_distance == high_distance:
                chosen = (upper - 1) if (upper - 1) % 2 == 0 else upper
        return sign | chosen
    checked = 0
    for bits in range(65536):
        if bits & 0x7C00 == 0x7C00:
            try:
                coefficient(bits)
            except ValueError:
                pass
            else:
                raise AssertionError("accepted nonfinite half")
            continue
        assert equal(round_half(coefficient(bits) << 24), bits)
        assert math.ldexp(coefficient(bits), -24) == struct.unpack("<e", struct.pack("<H", bits))[0]
        checked += 1
    for left, right in zip(representable, representable[1:]):
        midpoint = (left + right) // 2
        for displacement in [-1, 0, 1]:
            for sign in [-1, 1]:
                value = sign * (midpoint + displacement)
                assert round_half(value) == neighbour_round(value)
                checked += 1
    for value in [0, 1, -1, overflow - 1, overflow, overflow + 1,
                  -overflow + 1, -overflow, -overflow - 1, 1 << 100, -(1 << 100)]:
        assert round_half(value) == neighbour_round(value)
        checked += 1
    # Exact cancellation chooses +0; negative tiny nonzero values round to -0.
    assert round_half((12345 * 67890) - (12345 * 67890)) == 0
    assert round_half(-1) == 0x8000
    assert ulps(0x8000, 0x0001) == 1
    assert ulps(0x8001, 0x0001) == 2
    assert ulps(0x8001, 0) == 1
    assert ulps(0x8000, 0) == 0
    assert ulps(0xBC00, 0xBC01) == 1
    return checked + 5


class SafeTensors:
    def __init__(self, path, expected_sha):
        size = Path(path).stat().st_size
        if not 8 <= size <= 64 * 1024 * 1024:
            raise ValueError("artifact size before allocation")
        data = Path(path).read_bytes()
        if len(data) != size or hashlib.sha256(data).hexdigest() != expected_sha:
            raise ValueError("artifact identity/size")
        length = struct.unpack_from("<Q", data)[0]
        if not 0 < length <= 4 * 1024 * 1024:
            raise ValueError("header size")
        self.header = json.loads(data[8:8 + length])
        self.payload = memoryview(data)[8 + length:]
    def tensor(self, name, dtype, shape):
        entry = self.header[name]
        begin, end = entry["data_offsets"]
        item_size = 2 if dtype == "F16" else 4
        if (entry["dtype"] != dtype or entry["shape"] != shape or
                not 0 <= begin <= end <= len(self.payload) or end - begin != math.prod(shape) * item_size):
            raise ValueError("tensor contract: " + name)
        result = array.array("H" if dtype == "F16" else "i")
        result.frombytes(self.payload[begin:end])
        if sys.byteorder != "little":
            result.byteswap()
        if dtype == "F16" and any(b & 0x7C00 == 0x7C00 for b in result):
            raise ValueError("nonfinite tensor: " + name)
        return result


def modules():
    for layer in range(30):
        for component, n, k in [("self_attn.q_proj", 1024, 1024), ("self_attn.k_proj", 1024, 1024),
                                ("self_attn.v_proj", 1024, 1024), ("self_attn.o_proj", 1024, 1024),
                                ("mlp.gate_proj", 4096, 1024), ("mlp.up_proj", 4096, 1024),
                                ("mlp.down_proj", 1024, 4096)]:
            yield f"tfmr.layers.{layer}.{component}", n, k


def analyze(cpu_path, gpu_path, preregistration, output):
    if Path(output).exists():
        raise ValueError("refusing to overwrite prior study")
    if hashlib.sha256(Path(preregistration).read_bytes()).hexdigest() != PREREG_SHA:
        raise ValueError("preregistration identity")
    began = time.monotonic()
    tests = self_test()
    cpu, gpu = SafeTensors(cpu_path, CPU_SHA), SafeTensors(gpu_path, GPU_SHA)
    names = [m[0] for m in modules()]
    cpu_keys = {name + "." + suffix for name in names for suffix in ["input", "weights", "row_ids", "cpu_half", "cpu_f32"]}
    gpu_keys = {name + "." + suffix for name in names for suffix in ["gpu_packed", "gpu_half", "gpu_f32"]}
    if set(cpu.header) - {"__metadata__"} != cpu_keys or set(gpu.header) - {"__metadata__"} != gpu_keys:
        raise ValueError("exact membership")
    coefficients = [None if b & 0x7C00 == 0x7C00 else coefficient(b) for b in range(65536)]
    floats = [None if c is None else (-0.0 if b == 0x8000 else math.ldexp(c, -24)) for b, c in enumerate(coefficients)]
    methods = ["cpu_half", "cpu_f32", "gpu_packed", "gpu_half", "gpu_f32"]
    summary = {m: {"exact_mismatches": 0, "rounded_product_mismatches": 0,
                   "signed_zero_only": 0, "max_half_ulp_from_exact": 0} for m in methods}
    paired = {m: {"mismatches_from_cpu_f32": 0, "max_half_ulp": 0} for m in methods[2:]}
    cases, kahan_differences, products = [], 0, 0
    for name, n, k in modules():
        if time.monotonic() - began > 180:
            raise TimeoutError("bounded exact study exceeded180seconds")
        ids = list(cpu.tensor(name + ".row_ids", "I32", [32]))
        if ids != [i * (n - 1) // 31 for i in range(32)]:
            raise ValueError("sample membership changed")
        x = cpu.tensor(name + ".input", "F16", [2, 1, k])
        w = cpu.tensor(name + ".weights", "F16", [32, k])
        outputs = {m: (cpu if m.startswith("cpu_") else gpu).tensor(name + "." + m, "F16", [2, 32]) for m in methods}
        for sample, row_id in enumerate(ids):
            weights = w[sample * k:(sample + 1) * k]
            for lane in [0, 1]:
                exact_sum, rounded_sum, compensation, floating_sum = 0, 0, 0.0, 0.0
                for xb, wb in zip(x[lane * k:(lane + 1) * k], weights):
                    product = coefficients[xb] * coefficients[wb]
                    exact_sum += product
                    rounded = round_half(product)
                    if coefficients[rounded] is None:
                        raise ValueError("nonfinite rounded product in fixed sample")
                    rounded_sum += coefficients[rounded]
                    term = floats[xb] * floats[wb]
                    adjusted = term - compensation
                    temporary = floating_sum + adjusted
                    compensation = (temporary - floating_sum) - adjusted
                    floating_sum = temporary
                    products += 1
                exact, half_products = round_half(exact_sum), round_half(rounded_sum << 24)
                if coefficients[exact] is None or coefficients[half_products] is None:
                    raise ValueError("nonfinite exact output in fixed sample")
                kahan = struct.unpack("<H", struct.pack("<e", floating_sum))[0]
                kahan_differences += not equal(kahan, exact)
                result = {m: outputs[m][lane * 32 + sample] for m in methods}
                for m, bits in result.items():
                    s = summary[m]
                    s["exact_mismatches"] += not equal(bits, exact)
                    s["rounded_product_mismatches"] += not equal(bits, half_products)
                    s["signed_zero_only"] += bits != exact and zero(bits) and zero(exact)
                    s["max_half_ulp_from_exact"] = max(s["max_half_ulp_from_exact"], ulps(bits, exact))
                for m, s in paired.items():
                    s["mismatches_from_cpu_f32"] += not equal(result[m], result["cpu_f32"])
                    s["max_half_ulp"] = max(s["max_half_ulp"], ulps(result[m], result["cpu_f32"]))
                cases.append({"module": name, "row": row_id, "lane": lane,
                              "exact": exact, "rounded_products": half_products, "kahan": kahan, **result})
    if len(cases) != 13440:
        raise ValueError("scalar sample count")
    report = {"completed": True, "diagnostic_only": True, "self_test_cases": tests,
              "preregistration_sha256": PREREG_SHA, "cpu_sha256": CPU_SHA, "gpu_sha256": GPU_SHA,
              "scalar_samples": len(cases), "exact_products": products, "methods": summary, "paired": paired,
              "kahan_mismatches_from_exact": kahan_differences, "cases": cases,
              "wall_seconds": time.monotonic() - began,
              "scope": "preregistered numerical study; no reference mutation, audio or inference clearance"}
    with Path(output).open("x") as stream:
        json.dump(report, stream, indent=2, sort_keys=True)
        stream.write("\n")
    return {k: v for k, v in report.items() if k != "cases"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    for argument in ["cpu", "gpu", "preregistration", "output"]:
        parser.add_argument("--" + argument)
    args = parser.parse_args()
    if args.self_test:
        print(json.dumps({"rounding_tests_passed": self_test()}))
    else:
        if not all([args.cpu, args.gpu, args.preregistration, args.output]):
            parser.error("cpu, gpu, preregistration and output required")
        print(json.dumps(analyze(args.cpu, args.gpu, args.preregistration, args.output), indent=2))
