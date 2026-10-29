#!/usr/bin/env python3
"""Independent scalar RoPE audit. No MLX/Torch, model, audio or oracle mutation.

The declared contract rounds each algebraic operation to IEEE binary32;
trig results round to binary32 and then binary16. Rotation rounds both half
products before the half addition/subtraction. This is a diagnostic contract,
not an accepted replacement model. Decimal transcendental bounds are stated
explicitly and unresolved rounding intervals fail closed.
"""
import argparse
import ctypes
from decimal import Decimal, localcontext
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct
import time
from exact_dot import SafeTensors, coefficient, round_half, ulps

FIXTURE = "e3155186f9f00f2c1c8409c35f2532bd6ea29c81798256bac68b61f383adc125"
PREREG = "6ed9e8fe6a632a5935ccb10655aa527010bbe0673780dcbbd5fbe5820a10ca7d"


class Budget:
    """Read-only macOS memory/thermal checks; caller cancellation stays fatal."""
    def __init__(self):
        self.began, self.last_health = time.monotonic(), 0
        self.system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.system.mach_host_self.restype = ctypes.c_uint
        self.host = self.system.mach_host_self()
        self.system.host_statistics64.argtypes = [ctypes.c_uint, ctypes.c_int,
                                                  ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        self.system.host_page_size.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_size_t)]
        self.foundation = ctypes.CDLL("/System/Library/Frameworks/Foundation.framework/Foundation")
        objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
        objc.objc_getClass.argtypes, objc.objc_getClass.restype = [ctypes.c_char_p], ctypes.c_void_p
        objc.sel_registerName.argtypes, objc.sel_registerName.restype = [ctypes.c_char_p], ctypes.c_void_p
        pointer = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
        process_class = objc.objc_getClass(b"NSProcessInfo")
        require(bool(process_class), "NSProcessInfo class unavailable")
        self.process = pointer(process_class, objc.sel_registerName(b"processInfo"))
        self.thermal_selector = objc.sel_registerName(b"thermalState")
        self.low_power_selector = objc.sel_registerName(b"isLowPowerModeEnabled")
        self.thermal = ctypes.CFUNCTYPE(ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
        self.boolean = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)(("objc_msgSend", objc))
        require(bool(self.process), "NSProcessInfo unavailable")

    def check(self):
        now = time.monotonic()
        require(now - self.began < 180, "audit180s bound")
        if now - self.last_health >= 1:
            # Same Mac free+inactive estimate as the SDK. os_proc_available_memory
            # returns0 without a jetsam limit, so it is not the Mac metric.
            stats, count, page = (ctypes.c_uint * 256)(), ctypes.c_uint(256), ctypes.c_size_t()
            require(self.system.host_statistics64(self.host, 4, stats, ctypes.byref(count)) == 0
                    and count.value >= 4 and self.system.host_page_size(self.host, ctypes.byref(page)) == 0,
                    "memory query guard")
            require((stats[0] + stats[2]) * page.value >= 1024 ** 3, "available memory guard")
            require(self.thermal(self.process, self.thermal_selector) in (0, 1), "serious/critical thermal guard")
            require(not self.boolean(self.process, self.low_power_selector), "low power mode guard")
            self.last_health = now


def require(ok, message):
    if not ok:
        raise ValueError(message)


def rounded_ratio(n, d, exponent_bits, fraction_bits, negative_zero=False):
    """Exact rational to IEEE nearest/ties-even, including signed underflow."""
    require(d > 0, "positive denominator")
    sign = (n < 0 or (n == 0 and negative_zero)) << (exponent_bits + fraction_bits)
    n = abs(n)
    if not n:
        return sign
    bias = (1 << (exponent_bits - 1)) - 1
    exponent = n.bit_length() - d.bit_length()
    if (n < d << exponent) if exponent >= 0 else (n << -exponent < d):
        exponent -= 1
    shift = fraction_bits - max(exponent, 1 - bias)
    a, b = (n << shift, d) if shift >= 0 else (n, d << -shift)
    q, r = divmod(a, b)
    if 2 * r > b or (2 * r == b and q & 1):
        q += 1
    if exponent < 1 - bias:
        return sign | q  # Includes carry from the subnormal range.
    if q == 1 << (fraction_bits + 1):
        q >>= 1
        exponent += 1
    if exponent > bias:
        return sign | (((1 << exponent_bits) - 1) << fraction_bits)
    return sign | ((exponent + bias) << fraction_bits) | (q - (1 << fraction_bits))


def d32(value):
    return rounded_ratio(*value.as_integer_ratio(), 8, 23, negative_zero=value.is_signed() and value.is_zero())


def value32(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def algebra(a, b, operation):
    x, y = Fraction(value32(a)), Fraction(value32(b))
    z = {"+": lambda: x + y, "-": lambda: x - y, "*": lambda: x * y, "/": lambda: x / y}[operation]()
    return rounded_ratio(z.numerator, z.denominator, 8, 23)


def half_from32(bits):
    value = value32(bits)
    return rounded_ratio(*value.as_integer_ratio(), 5, 10, negative_zero=bits == 0x80000000)


def decimal_pi():
    def atan_inverse(q):
        x = Decimal(1) / q
        power, total, index = x, Decimal(0), 0
        while True:
            term = power / (2 * index + 1)
            total += term if index % 2 == 0 else -term
            if abs(term) < Decimal("1e-115"):
                return total
            power *= x * x
            index += 1
    return 16 * atan_inverse(5) - 4 * atan_inverse(239)


def unambiguous32(value, error=Decimal("1e-90")):
    lo, hi = d32(value - error), d32(value + error)
    require(lo == hi, "unresolved Decimal-to-binary32 rounding interval")
    return lo


def frequencies(pi):
    f = lambda x: d32(Decimal(x))
    root = Decimal(500000)
    for _ in range(5):
        root = root.sqrt()
    twopi = algebra(f(2), unambiguous32(pi), "*")
    result = []
    for i in range(32):
        frequency = unambiguous32(root ** i) if i else f(1)
        wavelength = algebra(twopi, frequency, "*")
        if value32(wavelength) > 8192:
            frequency = algebra(frequency, f(8), "*")
        if 2048 < value32(wavelength) < 8192:
            smooth = algebra(algebra(algebra(f(8192), wavelength, "/"), f(1), "-"), f(3), "/")
            denominator = algebra(algebra(algebra(f(1), smooth, "-"), f(8), "/"), smooth, "+")
            frequency = algebra(frequency, denominator, "/")
        result.append(frequency)
    return result


def trig32(phase, pi):
    if phase == 0:
        return 0x3F800000, 0  # Exact special case, no interval straddling zero.
    x = Decimal.from_float(value32(phase))
    x -= (x / (2 * pi)).to_integral_value(rounding="ROUND_HALF_EVEN") * (2 * pi)
    square = x * x
    def series(sine):
        term = total = x if sine else Decimal(1)
        for i in range(1, 256):
            term *= -square / ((2 * i) * (2 * i + 1) if sine else (2 * i - 1) * (2 * i))
            total += term
            if abs(term) < Decimal("1e-110"):
                return unambiguous32(total)
        raise ValueError("Taylor iteration bound")
    return series(False), series(True)


def half_product(a, b):
    integer = coefficient(a) * coefficient(b)
    return ((a ^ b) & 0x8000) if integer == 0 else round_half(integer)


def half_sum(a, b):
    integer = coefficient(a) + coefficient(b)
    # IEEE round-to-nearest: opposite signs cancel to +0, -0 plus -0 is -0.
    return (a & b & 0x8000) if integer == 0 else round_half(integer << 24)


def rotate(inputs, cosines, sines):
    require(len(inputs) % 64 == 0 and len(cosines) == len(sines) == 32, "rotation shapes")
    output = []
    for offset in range(0, len(inputs), 64):
        first, second = [], []
        for j in range(32):
            a, b, c, s = inputs[offset + j], inputs[offset + j + 32], cosines[j], sines[j]
            first.append(half_sum(half_product(a, c), half_product(b, s) ^ 0x8000))
            second.append(half_sum(half_product(a, s), half_product(b, c)))
        output.extend(first + second)
    return output


def analyze(fixture_path, prereg_path, output):
    require(not output.exists(), "preserve prior audit")
    require(hashlib.sha256(prereg_path.read_bytes()).hexdigest() == PREREG, "preregistration identity")
    budget = Budget()
    budget.check()
    began = budget.began
    fixture = SafeTensors(fixture_path, FIXTURE)
    expected_keys = {"rope.cosines", "rope.sines"}
    expected_keys |= {f"rope.{i}.{s}" for i in range(60) for s in ("input", "output", "frequencies")}
    expected_keys |= {f"layer.{i}.{s}" for i in range(30) for s in ("keys", "values")}
    require(set(fixture.header) - {"__metadata__"} == expected_keys, "fixture membership")
    imported = [v & 0xFFFFFFFF for v in fixture.tensor("rope.0.frequencies", "F32", [32])]
    require(all(0 < value32(v) < float("inf") for v in imported), "finite positive frequencies")
    for i in range(60):
        require([v & 0xFFFFFFFF for v in fixture.tensor(f"rope.{i}.frequencies", "F32", [32])] == imported,
                "inconsistent capture frequencies")
    cpu_c = fixture.tensor("rope.cosines", "F16", [1536, 32])
    cpu_s = fixture.tensor("rope.sines", "F16", [1536, 32])
    tables, stats, rows, cache = {}, {}, {}, {}
    with localcontext() as context:
        context.prec = 120
        pi = decimal_pi()
        independent = frequencies(pi)
        for name, freq in (("independentFrequencies", independent), ("importedFrequencies", imported)):
            reciprocals = [algebra(0x3F800000, f, "/") for f in freq]
            cosines, sines, mismatches, paired = [], [], [], bytearray()
            for position in range(1536):
                budget.check()
                for j, inverse in enumerate(reciprocals):
                    phase = algebra(d32(Decimal(position)), inverse, "*")
                    if phase not in cache:
                        cache[phase] = trig32(phase, pi)
                    c32, s32 = cache[phase]
                    c16, s16 = half_from32(c32), half_from32(s32)
                    index = position * 32 + j
                    cosines.append(c16); sines.append(s16)
                    # Exact layout is pinned in report, all paired bits retained.
                    paired.extend(struct.pack("<IHIIIHHHH", position, j, phase, c32, s32, c16, s16, cpu_c[index], cpu_s[index]))
                    if c16 != cpu_c[index] or s16 != cpu_s[index]:
                        mismatches.append(dict(position=position, frequency=j, expected_cos=c16,
                            actual_cos=cpu_c[index], expected_sin=s16, actual_sin=cpu_s[index],
                            cos_half_ulps=ulps(c16, cpu_c[index]), sin_half_ulps=ulps(s16, cpu_s[index])))
            tables[name] = cosines, sines
            rows[name] = paired
            stats[name] = dict(paired_positions=49152, trig_half_values=98304, mismatching_positions=mismatches)
    rotations = {}
    for name, (cosines, sines) in dict(tables, importedCPUTables=(cpu_c, cpu_s)).items():
        differences = []
        for i in range(60):
            budget.check()
            inputs = fixture.tensor(f"rope.{i}.input", "F16", [2, 16, 1, 64])
            expected = fixture.tensor(f"rope.{i}.output", "F16", [2, 16, 1, 64])
            actual = rotate(inputs, cosines[95 * 32:96 * 32], sines[95 * 32:96 * 32])
            differences.extend(dict(capture=i, index=j, independent=a, cpu=b, half_ulps=ulps(a, b))
                               for j, (a, b) in enumerate(zip(actual, expected)) if a != b)
        rotations[name] = dict(values=122880, differences=differences)
    report = dict(completed=True, diagnostic_only=True, production_clearance=False,
        fixture_sha256=FIXTURE, preregistration_sha256=PREREG,
        contract="RNE32 frequency algebra/reciprocal/phase/trig, thenRNE16 trig; RNE16 products then sums",
        transcendental_assumption="Decimal120digit Machin/Taylor with1e-90 enclosure; all enclosures must round to onebinary32. This is an explicitly stated numerical bound, not a formal interval proof of Decimal implementation.",
        frequency_pairs=[dict(index=i, independent=a, cpu=b, equal=a == b) for i, (a, b) in enumerate(zip(independent, imported))],
        tables=stats, rotations=rotations, paired_row_format="little-endian <IHIIIHHHH:position,frequency,phaseF32,cosF32,sinF32,cosF16,sinF16,cpuCosF16,cpuSinF16",
        wall_seconds=time.monotonic() - began,
        limits="Independent scalar RoPE audit only; no whole-model reference/profile, phone, audio or speed acceptance")
    budget.check()
    output.mkdir(parents=False, exist_ok=False)
    for name, data in rows.items():
        (output / (name + ".bin")).write_bytes(data)
        stats[name]["paired_sha256"] = hashlib.sha256(data).hexdigest()
    budget.check()
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture", type=Path)
    parser.add_argument("preregistration", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    analyze(args.fixture, args.preregistration, args.output)
