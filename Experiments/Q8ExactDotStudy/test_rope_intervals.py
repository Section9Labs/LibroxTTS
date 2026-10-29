from decimal import Decimal, localcontext
from fractions import Fraction
import random
import unittest
import tempfile
from pathlib import Path
from rope_intervals import Interval, rational_interval, pi_interval, certified_trig, exact_power_frequency
from rope_semantics import d32


class IntervalTests(unittest.TestCase):
    def test_directed_basic_ops_enclose_exact_rationals(self):
        rng = random.Random(412)
        for _ in range(200):
            a, b, c, d = [rng.randrange(1, 100000) for _ in range(4)]
            x, y = Fraction(a, b), Fraction(-c, d)
            i, j = rational_interval(a, b), -rational_interval(c, d)
            for interval, exact in ((i + j, x + y), (i - j, x - y), (i * j, x * y), (i / j, x / y)):
                self.assertLessEqual(Fraction(interval.low), exact)
                self.assertGreaterEqual(Fraction(interval.high), exact)

    def test_pi_interval_and_rounding_ambiguity(self):
        pi = pi_interval()
        def exact_atan(q):
            total = sum((Fraction((-1) ** i, (2 * i + 1) * q ** (2 * i + 1)) for i in range(200)), Fraction())
            error = Fraction(1, 401 * q ** 401)
            return total - error, total + error
        a, b = exact_atan(5), exact_atan(239)
        self.assertLessEqual(Fraction(pi.low), 16 * a[0] - 4 * b[1])
        self.assertGreaterEqual(Fraction(pi.high), 16 * a[1] - 4 * b[0])
        with self.assertRaises(ValueError):
            Interval(0, 1).rounded32()
        with self.assertRaises(ValueError):
            Interval(1) / Interval(-1, 1)

    def test_exact_power_frequency_midpoints(self):
        with localcontext() as context:
            context.prec = 160
            root = Decimal(500000)
            for _ in range(5):
                root = root.sqrt()
            for i in range(32):
                self.assertEqual(exact_power_frequency(i), d32(root ** i))

    def test_directed_trig_and_later_disagreement_case(self):
        import math
        pi = pi_interval()
        for value in (0, .1, 1, 95, 255, 494, 1535):
            bits = d32(Decimal(str(value)))
            c, s = certified_trig(bits, pi)
            from rope_semantics import value32
            self.assertEqual(c, d32(Decimal.from_float(math.cos(value32(bits)))))
            self.assertEqual(s, d32(Decimal.from_float(math.sin(value32(bits)))))
        # Pinned CPU trig discrepancy atposition494/frequency7, imported phase.
        self.assertEqual(certified_trig(1105196373, pi)[0], 3212185601)

    def test_wrong_candidate_identity_rejected_before_read(self):
        from unittest.mock import patch
        from rope_intervals import certify
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch("rope_intervals.Budget"):
                # No candidate exists: identity must fail before stat/read.
                with self.assertRaises(ValueError):
                    certify(root, root / "new-output", "unfrozen hash")
            self.assertFalse((root / "new-output").exists())


if __name__ == "__main__":
    unittest.main()
