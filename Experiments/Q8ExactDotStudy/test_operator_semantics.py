from decimal import Decimal, localcontext
from fractions import Fraction
import json
import math
from pathlib import Path
import random
import struct
import tempfile
import unittest
from unittest.mock import patch
from operator_semantics import (coefficient32, add32, multiply32, exact_dot, reciprocal_sqrt32,
                                exp_interval, sigmoid32, softmax32, Recorder, publish, analyze, WeightRows)
from rope_semantics import d32, rounded_ratio, value32
from rope_intervals import Interval


class NumericTests(unittest.TestCase):
    def test_integer_operations_match_independent_double_exact_cases(self):
        rng = random.Random(41282)
        for _ in range(2048):
            a, b = [rng.randrange(0x3D000000, 0x41000000) | (rng.randrange(2) << 31) for _ in range(2)]
            x, y = value32(a), value32(b)
            for actual, value in ((add32(a, b), x + y), (multiply32(a, b), x * y)):
                expected, = struct.unpack("<I", struct.pack("<f", value))
                self.assertEqual(actual, expected)
        self.assertEqual(add32(0x80000000, 0x80000000), 0x80000000)
        self.assertEqual(add32(0x3F800000, 0xBF800000), 0)
        self.assertEqual(multiply32(0x80000000, 0x3F800000), 0x80000000)
        with self.assertRaises(ValueError):
            coefficient32(0x7F800000)
        with self.assertRaises(ValueError):
            exact_dot([1], [])

    def test_exact_dot_against_fraction(self):
        values = [0x3F800000, 0xBF800000, 0x00000001, 0x3F000000]
        a, b = values, list(reversed(values))
        exact = sum((Fraction(value32(x)) * Fraction(value32(y)) for x, y in zip(a, b)), Fraction())
        self.assertEqual(exact_dot([coefficient32(x) for x in a], [coefficient32(x) for x in b]),
                         rounded_ratio(exact.numerator, exact.denominator, 8, 23))

    def test_inverse_root_matches_high_precision_with_boundary_cases(self):
        with localcontext() as context:
            context.prec = 160
            for bits in (1, 0x007FFFFF, 0x00800000, 0x3F000000, 0x3F800000, 0x40000000, 0x7F7FFFFF):
                exact = Decimal(1) / Decimal.from_float(value32(bits)).sqrt()
                self.assertEqual(reciprocal_sqrt32(bits), d32(exact))
        with self.assertRaises(ValueError):
            reciprocal_sqrt32(0)

    def test_exp_interval_against_exact_rational_taylor_bracket(self):
        total = sum((Fraction(1, math.factorial(i)) for i in range(150)), Fraction())
        error = Fraction(3, math.factorial(150))
        positive = exp_interval(Interval(1))
        self.assertLessEqual(Fraction(positive.low), total)
        self.assertGreaterEqual(Fraction(positive.high), total + error)
        negative = exp_interval(Interval(-1))
        self.assertLessEqual(Fraction(negative.low), 1 / (total + error))
        self.assertGreaterEqual(Fraction(negative.high), 1 / total)

    def test_sigmoid_and_stable_softmax_math_controls(self):
        f = lambda x: d32(Decimal(x))
        self.assertEqual(sigmoid32(f(0)), f("0.5"))
        self.assertEqual(sigmoid32(f(200)), f(1))
        self.assertEqual(sigmoid32(f(-200)), f(0))
        self.assertEqual(softmax32([f(0)] * 4), [f("0.25")] * 4)
        self.assertEqual(softmax32([f(200), f(200), f(-200)]), [f("0.5"), f("0.5"), 0])
        self.assertEqual(softmax32([f(1000), f(0)]), [f(1), f(0)])
        self.assertEqual(softmax32([f(1), f(2), f(3)]), softmax32([f(1001), f(1002), f(1003)]))
        with self.assertRaises(ValueError):
            softmax32([])


class PublicationTests(unittest.TestCase):
    class Budget:
        def __init__(self, fail_at=None):
            import time
            self.calls, self.fail_at, self.began = 0, fail_at, time.monotonic()
        def check(self):
            self.calls += 1
            if self.calls == self.fail_at:
                raise InterruptedError("forced resource/cancellation boundary")

    def test_first_middle_last_cancellation_never_publishes_completion(self):
        for failure in (1, 2, 3):
            with tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "new"
                budget = self.Budget(failure)
                recorder = Recorder(budget)
                recorder.outputs["test"] = ([2], [0, 0x80000000])
                with self.assertRaises(InterruptedError):
                    publish(output, recorder, dict(completed=True, production_clearance=False), budget)
                self.assertFalse((output / "report.json").exists())

    def test_wrong_identity_stops_before_health_or_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prereg = root / "prereg.json"
            prereg.write_text("{}")
            with patch("operator_semantics.Budget") as budget:
                with self.assertRaises(ValueError):
                    analyze(root / "absent", root / "absent", prereg, root / "new")
                budget.assert_not_called()
            self.assertFalse((root / "new").exists())
            with self.assertRaises(ValueError):
                WeightRows(prereg, self.Budget())

    def test_success_receipt_hash_and_signed_zero_bits(self):
        with tempfile.TemporaryDirectory() as temporary:
            import hashlib
            output = Path(temporary) / "new"
            budget = self.Budget()
            recorder = Recorder(budget)
            recorder.outputs["test"] = ([2], [0, 0x80000000])
            publish(output, recorder, dict(completed=True, production_clearance=False), budget)
            report = json.loads((output / "report.json").read_text())
            raw = (output / "independent-operator-bits.safetensors").read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), report["raw_sha256"])
            size, = struct.unpack_from("<Q", raw)
            self.assertEqual(raw[8 + size:], struct.pack("<II", 0, 0x80000000))


if __name__ == "__main__":
    unittest.main()
