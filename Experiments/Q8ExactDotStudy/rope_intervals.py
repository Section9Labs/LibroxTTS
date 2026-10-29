#!/usr/bin/env python3
"""Directed-rounding certificate for the frozen diagnostic RoPE table.

Frequency powers are decided by exact rational midpoint^32 comparisons.
Machin atan and trig Taylor intervals include explicit real remainder bounds.
No model, production profile, audio or accepted oracle is written.
"""
from decimal import Decimal, Context, ROUND_FLOOR, ROUND_CEILING
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
from rope_semantics import Budget, algebra, d32, half_from32, rounded_ratio, value32, require

DOWN = Context(prec=120, rounding=ROUND_FLOOR)
UP = Context(prec=120, rounding=ROUND_CEILING)
CANDIDATE_SHA = "9a98852ce789afaee9c55e35a4990bc5312fa271e080cd5f166c8b3979cdc34b"
PARENT_SHA = "e5e310f848da0a2f92e1d4cb443c3f508f0f65032a049e9de557f44e38b84b90"


class Interval:
    def __init__(self, low, high=None):
        self.low = Decimal(low)
        self.high = self.low if high is None else Decimal(high)
        require(self.low.is_finite() and self.high.is_finite() and self.low <= self.high, "invalid interval")

    def __add__(self, other):
        return Interval(DOWN.add(self.low, other.low), UP.add(self.high, other.high))

    def __neg__(self):
        return Interval(self.high.copy_negate(), self.low.copy_negate())

    def __sub__(self, other):
        return self + -other

    def __mul__(self, other):
        pairs = [(a, b) for a in (self.low, self.high) for b in (other.low, other.high)]
        return Interval(min(DOWN.multiply(a, b) for a, b in pairs), max(UP.multiply(a, b) for a, b in pairs))

    def __truediv__(self, other):
        require(not other.low <= 0 <= other.high, "interval division by zero")
        return self * Interval(DOWN.divide(Decimal(1), other.high), UP.divide(Decimal(1), other.low))

    def rounded32(self):
        a, b = d32(self.low), d32(self.high)
        require(a == b, "unresolved directed binary32 interval")
        return a


def rational_interval(n, d):
    return Interval(DOWN.divide(Decimal(n), Decimal(d)), UP.divide(Decimal(n), Decimal(d)))


def pi_interval():
    def atan(q):
        total = Interval(0)
        count = 100
        for i in range(count):
            term = rational_interval(1, (2 * i + 1) * q ** (2 * i + 1))
            total = total + (term if i % 2 == 0 else -term)
        # Alternating-series remainder <= next term, valid at 0 <1/q<1.
        error = rational_interval(1, (2 * count + 1) * q ** (2 * count + 1)).high
        return total + Interval(error.copy_negate(), error)
    return Interval(16) * atan(5) - Interval(4) * atan(239)


def exact_power_frequency(i):
    require(0 <= i < 32, "frequency index")
    target = 500000 ** i
    low, high = 0x3F800000, struct.unpack("<I", struct.pack("<f", 500000))[0]
    def compare(bits):
        value = Fraction(value32(bits))
        return value.numerator ** 32 - target * value.denominator ** 32
    while low < high:
        middle = (low + high) // 2
        if compare(middle) < 0:
            low = middle + 1
        else:
            high = middle
    if compare(low) == 0:
        return low
    midpoint = (Fraction(value32(low)) + Fraction(value32(low - 1))) / 2
    side = midpoint.numerator ** 32 - target * midpoint.denominator ** 32
    return low if side < 0 or (side == 0 and low % 2 == 0) else low - 1


def certified_frequencies(pi):
    f = lambda x: rounded_ratio(x, 1, 8, 23)
    twopi = algebra(f(2), pi.rounded32(), "*")
    result = []
    for i in range(32):
        frequency = exact_power_frequency(i)
        wavelength = algebra(twopi, frequency, "*")
        if value32(wavelength) > 8192:
            frequency = algebra(frequency, f(8), "*")
        if 2048 < value32(wavelength) < 8192:
            smooth = algebra(algebra(algebra(f(8192), wavelength, "/"), f(1), "-"), f(3), "/")
            denominator = algebra(algebra(algebra(f(1), smooth, "-"), f(8), "/"), smooth, "+")
            frequency = algebra(frequency, denominator, "/")
        result.append(frequency)
    return result


def certified_trig(phase_bits, pi):
    if phase_bits == 0:
        return 0x3F800000, 0
    x = Interval(Decimal.from_float(value32(phase_bits)))
    # This integer is only a range-reduction choice. The directed subtraction
    # encloses the exact value for ANY integer; the |x|<=4 guard validates tails.
    turns = int(round(value32(phase_bits) / (2 * math.pi)))
    x = x - Interval(2 * turns) * pi
    require(x.low >= -4 and x.high <= 4, "Taylor domain")
    square = x * x
    def series(sine):
        term = total = x if sine else Interval(1)
        for i in range(1, 48):
            denominator = (2 * i) * (2 * i + 1) if sine else (2 * i - 1) * (2 * i)
            term = -(term * square / Interval(denominator))
            total = total + term
        # Taylor polynomial through degree96(sin) or95(cos). The missing
        # parity coefficient is zero. Real derivatives of sin/cos have |f|<=1.
        degree = 97 if sine else 96
        tail = rational_interval(4 ** degree, math.factorial(degree)).high
        return (total + Interval(tail.copy_negate(), tail)).rounded32()
    return series(False), series(True)


def certify(root, output, expected_candidate_sha):
    require(not output.exists(), "preserve prior certificate")
    budget = Budget()
    budget.check()
    row = struct.Struct("<IHIIIHHHH")
    candidate_path, parent_path = root / "independentFrequencies.bin", root / "report.json"
    require(expected_candidate_sha == CANDIDATE_SHA and candidate_path.stat().st_size == row.size * 49152,
            "candidate identity/size before allocation")
    require(0 < parent_path.stat().st_size <= 2_000_000, "parent report size")
    candidate = candidate_path.read_bytes()
    require(len(candidate) == row.size * 49152 and hashlib.sha256(candidate).hexdigest() == expected_candidate_sha,
            "frozen candidate identity")
    parent = parent_path.read_bytes()
    require(hashlib.sha256(parent).hexdigest() == PARENT_SHA, "parent report identity")
    report = json.loads(parent)
    require(report["completed"] is True and report["production_clearance"] is False, "parent scope")
    pi = pi_interval()
    frequencies = certified_frequencies(pi)
    require([x["independent"] for x in report["frequency_pairs"]] == frequencies, "exact frequency certificate")
    inverse = [algebra(0x3F800000, f, "/") for f in frequencies]
    cache, cosines, sines = {}, [], []
    for index, record in enumerate(row.iter_unpack(candidate)):
        if index % 32 == 0:
            budget.check()
        position, j, phase, c32, s32, c16, s16, _, _ = record
        require((position, j) == divmod(index, 32), "all-position membership")
        expected_phase = algebra(rounded_ratio(position, 1, 8, 23), inverse[j], "*")
        require(phase == expected_phase, "exact phase certificate")
        if phase not in cache:
            cache[phase] = certified_trig(phase, pi)
        require((c32, s32) == cache[phase] and (c16, s16) == (half_from32(c32), half_from32(s32)),
                "directed trig/half certificate")
        cosines.append(c16); sines.append(s16)
    budget.check()
    # Flat deterministic diagnostic table:32 little-endian F32 frequency bits,
    # then1536x32 cosine F16 bits, then1536x32 sine F16 bits. Not an app oracle.
    data = struct.pack("<32I", *frequencies) + struct.pack("<49152H", *cosines) + struct.pack("<49152H", *sines)
    result = dict(completed=True, diagnostic_only=True, production_clearance=False,
        candidate_sha256=expected_candidate_sha, parent_report_sha256=PARENT_SHA,
        exact_power_frequency_certificates=32,
        exact_phase_certificates=49152, directed_trig_F32_certificates=98304,
        F32_to_F16_certificates=98304, pi_lower=str(pi.low), pi_upper=str(pi.high),
        method="Exact rational midpoint powers; directed Decimal120 interval arithmetic; explicit Machin/Taylor real remainders",
        numerical_assumptions="Python integer arithmetic exact; Decimal basic operations correctly directed per decimal module contract. No assumed1e-90 transcendental enclosure.",
        diagnostic_table_sha256=hashlib.sha256(data).hexdigest(), diagnostic_table_bytes=len(data),
        table_format="32u32frequencybits,49152u16cosines,49152u16sines; little-endian",
        limits="Certifies only this declared RoPE table, not remaining operators, full model, app, phone, sound or speed",
        wall_seconds=__import__("time").monotonic() - budget.began)
    output.mkdir(exist_ok=False)
    (output / "independent-rope-diagnostic-v01.bin").write_bytes(data)
    budget.check()
    (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    require(len(sys.argv) == 4, "usage: rope_intervals.py AUDIT_ROOT NEW_OUTPUT CANDIDATE_SHA256")
    certify(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
