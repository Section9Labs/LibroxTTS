#!/usr/bin/env python3
"""Preregistered same-input scalar arithmetic audit; not a model oracle.

No MLX/Torch, model execution, audio, profile selection or threshold changes.
Every reduction is exact integer arithmetic. Decimal's correctly-rounded exp
is enclosed by adjacent120-digit values before sigmoid/softmax rounding.
"""
from array import array
from decimal import Decimal, Context, ROUND_HALF_EVEN
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys
import time
from exact_dot import SafeTensors
from rope_semantics import Budget, rounded_ratio, value32, half_from32, require
from rope_intervals import Interval, rational_interval

PREREG = "a92b111157991a7c1654d2dc3f619469951359a0f528055ab48009536024aa02"
PRIMITIVES = "ba0a7add438d5f1326ce7aa541339cee4b2d3d3d973c3f56ddfb6019b00d38d4"
WEIGHTS = "231647ebb4deedad901c46cf3d7ca1e0fa70371b461c934c14dc63f16ec69017"
NEAR = Context(prec=120, rounding=ROUND_HALF_EVEN)
ONE = 0x3F800000


def coefficient32(bits):
    exponent = (bits >> 23) & 255
    require(exponent != 255, "nonfinite F32")
    n = bits & 0x7FFFFF
    if exponent:
        n = (n | 0x800000) << (exponent - 1)
    return -n if bits & 0x80000000 else n


def rn(n, scale):
    bits = rounded_ratio(n, 1 << scale, 8, 23)
    require(bits & 0x7F800000 != 0x7F800000, "F32 arithmetic overflow")
    return bits


def add32(a, b):
    n = coefficient32(a) + coefficient32(b)
    return rn(n, 149) if n else a & b & 0x80000000


def multiply32(a, b):
    n = coefficient32(a) * coefficient32(b)
    return rn(n, 298) if n else (a ^ b) & 0x80000000


def exact_dot(a, b):
    require(len(a) == len(b), "dot shape")
    return rn(sum(x * y for x, y in zip(a, b)), 298)


def reciprocal_sqrt32(bits):
    z = coefficient32(bits)
    require(z > 0, "positive norm variance")
    target = 1 << 447
    low, high = 0, 0x7F7FFFFF
    while low < high:
        middle = (low + high) // 2
        if coefficient32(middle) ** 2 * z < target:
            low = middle + 1
        else:
            high = middle
    require(low > 0, "inverse-root range")
    if coefficient32(low) ** 2 * z == target:
        return low
    midpoint_twice = coefficient32(low) + coefficient32(low - 1)
    side = midpoint_twice ** 2 * z - 4 * target
    return low if side < 0 or (side == 0 and low % 2 == 0) else low - 1


def exp_interval(x):
    if x.low == x.high == 0:
        return Interval(1)
    # decimal.Context.exp is correctly rounded (ROUND_HALF_EVEN). Adjacent
    # representables enclose its exact real value, including endpoint error.
    lower, upper = NEAR.exp(x.low), NEAR.exp(x.high)
    return Interval(NEAR.next_minus(lower), NEAR.next_plus(upper))


def sigmoid32(bits):
    x = value32(bits)
    if x >= 200:
        return ONE  # 1-sigmoid(x)<exp(-200)<2^-200, below the F32 half-cell.
    if x <= -200:
        return 0
    exact = Interval(Decimal.from_float(x))
    if x >= 0:
        return (Interval(1) / (Interval(1) + exp_interval(-exact))).rounded32()
    e = exp_interval(exact)
    return (e / (Interval(1) + e)).rounded32()


def softmax32(scores):
    require(bool(scores), "nonempty softmax")
    maximum = max(value32(b) for b in scores)
    terms = []
    for bits in scores:
        delta = Interval(Decimal.from_float(value32(bits))) - Interval(Decimal.from_float(maximum))
        # e^-200<2^-200; keep an enclosing term instead of dropping its mass.
        term = Interval(0, rational_interval(1, 1 << 200).high) if delta.high <= -200 else exp_interval(delta)
        terms.append(term)
    denominator = Interval(0)
    for term in terms:
        denominator = denominator + term
    return [(term / denominator).rounded32() for term in terms]


def lift_half(bits):
    value, = struct.unpack("<e", struct.pack("<H", bits))
    require(math.isfinite(value), "finite half")
    return struct.unpack("<I", struct.pack("<f", value))[0]


class WeightRows:
    def __init__(self, path, budget):
        require(path.stat().st_size == 568662708, "weight size before allocation")
        self.file = path.open("rb")
        self.identity = os.fstat(self.file.fileno())
        try:
            digest = hashlib.sha256()
            while data := self.file.read(1048576):
                budget.check()
                digest.update(data)
            require(digest.hexdigest() == WEIGHTS, "pinned weight identity")
            self.file.seek(0)
            length, = struct.unpack("<Q", self.file.read(8))
            require(0 < length < 4000000, "weight header bound")
            self.header = json.loads(self.file.read(length))
            require(len(set(self.header) - {"__metadata__"}) == 692, "weight membership")
            self.offset = 8 + length
            self.size = path.stat().st_size
        except BaseException:
            self.file.close()
            raise

    def row(self, name, shape, row=0):
        entry = self.header[name]
        start, end = entry["data_offsets"]
        require(entry["dtype"] == "F32" and entry["shape"] == shape and
                end - start == math.prod(shape) * 4 and 0 <= start < end <= self.size - self.offset,
                "weight tensor contract")
        count = shape[-1]
        require(0 <= row < (1 if len(shape) == 1 else shape[0]), "weight row")
        self.file.seek(self.offset + start + row * count * 4)
        raw = self.file.read(count * 4)
        require(len(raw) == count * 4, "weight read")
        bits = list(struct.unpack("<" + str(count) + "I", raw))
        for b in bits:
            coefficient32(b)
        return bits

    def unchanged(self):
        current = os.fstat(self.file.fileno())
        require((current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) ==
                (self.identity.st_dev, self.identity.st_ino, self.identity.st_size, self.identity.st_mtime_ns),
                "weights changed during audit")


class Recorder:
    def __init__(self, budget):
        self.rows, self.outputs, self.budget = [], {}, budget

    def compare(self, name, actual, expected, shape):
        require(len(actual) == len(expected) == math.prod(shape) and name not in self.outputs, "output shape/membership")
        different, half_different, maximum, squared, norm, max_ulp = 0, 0, 0.0, 0.0, 0.0, 0
        def ordered(bits):
            return -(bits & 0x7FFFFFFF) if bits & 0x80000000 else bits
        for i, (a, b) in enumerate(zip(actual, expected)):
            if i % 256 == 0:
                self.budget.check()
            coefficient32(a); coefficient32(b)
            different += a != b
            half_different += half_from32(a) != half_from32(b)
            max_ulp = max(max_ulp, abs(ordered(a) - ordered(b)))
            x, y = value32(a), value32(b)
            d = x - y
            maximum = max(maximum, abs(d)); squared += d * d; norm += y * y
        row = dict(name=name, count=len(actual), unequal_F32_bits=different, unequal_half_cast_bits=half_different,
                   max_F32_ulp=max_ulp, max_abs=maximum, relative_l2=math.sqrt(squared / max(norm, 1e-30)))
        self.rows.append(row)
        self.outputs[name] = (shape, actual)
        return row


def publish(output, recorder, report, budget):
    budget.check()
    require(not output.exists(), "preserve old audit")
    output.mkdir(exist_ok=False)
    header, payload = {}, bytearray()
    for name, (shape, bits) in sorted(recorder.outputs.items()):
        budget.check()
        raw = array("I", bits)
        if sys.byteorder != "little":
            raw.byteswap()
        begin = len(payload); payload.extend(raw.tobytes())
        header[name] = dict(dtype="F32", shape=shape, data_offsets=[begin, len(payload)])
    header["__metadata__"] = dict(scope="Independent operator diagnostic; not app oracle")
    metadata = json.dumps(header, separators=(",", ":")).encode()
    metadata += b" " * ((8 - len(metadata) % 8) % 8)
    data = struct.pack("<Q", len(metadata)) + metadata + payload
    (output / "independent-operator-bits.safetensors").write_bytes(data)
    report.update(raw_sha256=hashlib.sha256(data).hexdigest(), operator_comparisons=recorder.rows,
                  wall_seconds=time.monotonic() - budget.began)
    budget.check()
    # Final completion receipt is the last write. No receipt on cancellation.
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


def analyze(primitive_path, weight_path, prereg_path, output):
    require(not output.exists(), "preserve prior audit")
    require(0 < prereg_path.stat().st_size < 65536 and
            hashlib.sha256(prereg_path.read_bytes()).hexdigest() == PREREG, "preregistration identity")
    budget = Budget(); budget.check()
    fixture = SafeTensors(primitive_path, PRIMITIVES)
    expected_keys = {"speech_head.input", "speech_head.output", "tfmr.norm.input", "tfmr.norm.output"}
    for i in range(30):
        stem = f"tfmr.layers.{i}"
        expected_keys |= {stem + "." + kind + "." + suffix for kind in ("input_layernorm", "post_attention_layernorm")
                          for suffix in ("input", "output")}
        expected_keys |= {stem + ".attention." + kind for kind in ("query", "key", "value", "output")}
        expected_keys.add(stem + ".mlp.activated")
        expected_keys |= {stem + "." + kind + "." + suffix
                          for kind in ("self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj", "self_attn.o_proj",
                                       "mlp.gate_proj", "mlp.up_proj", "mlp.down_proj") for suffix in ("input", "output")}
    require(set(fixture.header) - {"__metadata__"} == expected_keys, "primitive membership")
    weights = WeightRows(weight_path, budget)
    recorder = Recorder(budget)
    def f32(name, shape):
        return [v & 0xFFFFFFFF for v in fixture.tensor(name, "F32", shape)]
    def f16(name, shape):
        return [lift_half(v) for v in fixture.tensor(name, "F16", shape)]
    try:
        epsilon = struct.unpack("<I", struct.pack("<f", 1e-5))[0]
        norm_names = [f"tfmr.layers.{i}.{kind}" for i in range(30)
                      for kind in ("input_layernorm", "post_attention_layernorm")] + ["tfmr.norm"]
        for name in norm_names:
            budget.check()
            x = f32(name + ".input", [2, 1, 1024]); w = weights.row(name + ".weight", [1024])
            actual = []
            for lane in range(2):
                values = x[lane * 1024:(lane + 1) * 1024]
                squares = [multiply32(v, v) for v in values]
                mean = rounded_ratio(sum(coefficient32(v) for v in squares), 1024 << 149, 8, 23)
                inverse = reciprocal_sqrt32(add32(mean, epsilon))
                actual.extend(multiply32(multiply32(v, inverse), scale) for v, scale in zip(values, w))
            recorder.compare(name, actual, f32(name + ".output", [2, 1, 1024]), [2, 1, 1024])
        sigmoid_cache = {}
        for i in range(30):
            stem = f"tfmr.layers.{i}"
            g = f16(stem + ".mlp.gate_proj.output", [2, 1, 4096])
            u = f16(stem + ".mlp.up_proj.output", [2, 1, 4096])
            actual = []
            for j, (gate, up) in enumerate(zip(g, u)):
                if j % 256 == 0:
                    budget.check()
                if gate not in sigmoid_cache:
                    sigmoid_cache[gate] = sigmoid32(gate)
                actual.append(multiply32(multiply32(gate, sigmoid_cache[gate]), up))
            recorder.compare(stem + ".mlp.activated", actual, f32(stem + ".mlp.activated", [2, 1, 4096]), [2, 1, 4096])
            # Mandatory association/control for captured activated->down input.
            require([half_from32(v) for v in f32(stem + ".mlp.activated", [2, 1, 4096])] ==
                    list(fixture.tensor(stem + ".mlp.down_proj.input", "F16", [2, 1, 4096])), "activation cast control")
        for i in range(30):
            budget.check()
            stem = f"tfmr.layers.{i}.attention"
            query = f32(stem + ".query", [2, 16, 1, 64])
            keys = f32(stem + ".key", [2, 16, 96, 64])
            values = f32(stem + ".value", [2, 16, 96, 64])
            actual, all_scores, all_probabilities = [], [], []
            for head in range(32):
                budget.check()
                q = [coefficient32(multiply32(v, 0x3E000000)) for v in query[head * 64:(head + 1) * 64]]
                k = [coefficient32(v) for v in keys[head * 6144:(head + 1) * 6144]]
                scores = [exact_dot(q, k[j * 64:(j + 1) * 64]) for j in range(96)]
                probability = softmax32(scores)
                p = [coefficient32(v) for v in probability]
                v = [coefficient32(x) for x in values[head * 6144:(head + 1) * 6144]]
                actual.extend(exact_dot(p, v[j::64]) for j in range(64))
                all_scores.extend(scores); all_probabilities.extend(probability)
            recorder.outputs[stem + ".scores"] = ([2, 16, 1, 96], all_scores)
            recorder.outputs[stem + ".probabilities"] = ([2, 16, 1, 96], all_probabilities)
            recorder.compare(stem, actual, f32(stem + ".output", [2, 16, 1, 64]), [2, 16, 1, 64])
        residual_exact = True
        for i in range(30):
            budget.check()
            stem = f"tfmr.layers.{i}"
            before = f32(stem + ".input_layernorm.input", [2, 1, 1024])
            attention = f16(stem + ".self_attn.o_proj.output", [2, 1, 1024])
            after = f32(stem + ".post_attention_layernorm.input", [2, 1, 1024])
            row = recorder.compare(stem + ".attention_residual", [add32(a, b) for a, b in zip(before, attention)], after, [2, 1, 1024])
            residual_exact &= row["unequal_F32_bits"] == 0
            down = f16(stem + ".mlp.down_proj.output", [2, 1, 1024])
            next_name = f"tfmr.layers.{i + 1}.input_layernorm.input" if i < 29 else "tfmr.norm.input"
            row = recorder.compare(stem + ".mlp_residual", [add32(a, b) for a, b in zip(after, down)],
                                   f32(next_name, [2, 1, 1024]), [2, 1, 1024])
            residual_exact &= row["unequal_F32_bits"] == 0
        hidden = f32("speech_head.input", [2, 1024])
        h = [[coefficient32(v) for v in hidden[lane * 1024:(lane + 1) * 1024]] for lane in range(2)]
        actual = [0] * 16388
        for j in range(8194):
            if j % 32 == 0:
                budget.check()
            w = [coefficient32(v) for v in weights.row("speech_head.weight", [8194, 1024], j)]
            for lane in range(2):
                actual[lane * 8194 + j] = exact_dot(h[lane], w)
        expected = f32("speech_head.output", [2, 8194])
        head = recorder.compare("speech_head", actual, expected, [2, 8194])
        lanes = []
        for lane in range(2):
            domain = range(lane * 8194, (lane + 1) * 8194)
            leader = max(domain, key=lambda j: value32(actual[j]))
            target = max(domain, key=lambda j: value32(expected[j]))
            lanes.append(dict(actual=leader - lane * 8194, captured=target - lane * 8194))
        # Original comparison arithmetic subtracts in F32 before Double metrics.
        difference = [value32(add32(a, b ^ 0x80000000)) for a, b in zip(actual, expected)]
        maximum = max(map(abs, difference))
        relative = math.sqrt(sum(v * v for v in difference) / max(sum(value32(v) ** 2 for v in expected), 1e-30))
        report = dict(completed=True, diagnostic_only=True, production_clearance=False, preregistration_sha256=PREREG,
            primitive_sha256=PRIMITIVES, weights_sha256=WEIGHTS, all60residual_additions_bit_identical=residual_exact,
            sigmoid_unique_inputs=len(sigmoid_cache), independent_operator_counts=dict(norm=61, silu=30, attention=30, residual=60, head=1),
            head_comparison=dict(max_abs=maximum, relative_l2=relative, lanes=lanes,
                passes_original_criteria=maximum <= .05 and relative <= .002 and all(x["actual"] == x["captured"] for x in lanes)),
            reference_scope="Strict preregistered array-sequence operator contracts, same captured inputs; not assembled full-model qualification",
            transcendental_contract="decimal.Context.exp correctly rounded, enclosed by adjacent120digit values; exact integer reductions and squared-midpoint inverse-root rounding",
            limits="No full-model reference, accepted profile, app/phone, audio, speed or battery clearance")
        require(len(recorder.rows) == 182, "all operator membership")
        weights.unchanged()
        publish(output, recorder, report, budget)
    finally:
        weights.file.close()


if __name__ == "__main__":
    require(len(sys.argv) == 5, "usage: operator_semantics.py PRIMITIVES Q8_WEIGHTS PREREG NEW_OUTPUT")
    analyze(*(Path(p) for p in sys.argv[1:]))
