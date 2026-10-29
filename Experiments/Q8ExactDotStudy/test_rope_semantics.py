from decimal import Decimal, localcontext
import math
import random
import struct
import unittest
from rope_semantics import (rounded_ratio, d32, value32, half_from32, half_product,
                            half_sum, decimal_pi, trig32, frequencies, rotate, unambiguous32)


class RoundingTests(unittest.TestCase):
    def test_all_finite_half_encodings_and_signed_zeros(self):
        for bits in range(65536):
            if bits & 0x7C00 == 0x7C00:
                continue
            value, = struct.unpack("<e", struct.pack("<H", bits))
            self.assertEqual(rounded_ratio(*value.as_integer_ratio(), 5, 10,
                                          negative_zero=bits == 0x8000), bits)

    def test_half_midpoints_both_sides_and_ties(self):
        for low in range(0x7BFF):
            a, = struct.unpack("<e", struct.pack("<H", low))
            b, = struct.unpack("<e", struct.pack("<H", low + 1))
            middle = (a + b) / 2
            for sign in (-1, 1):
                for value in (math.nextafter(middle, -math.inf), middle, math.nextafter(middle, math.inf)):
                    x = sign * value
                    expected, = struct.unpack("<H", struct.pack("<e", x))
                    self.assertEqual(rounded_ratio(*x.as_integer_ratio(), 5, 10), expected)

    def test_f32_boundary_rounding(self):
        for bits in (0, 1, 0x007FFFFF, 0x00800000, 0x3F7FFFFF, 0x3F800000, 0x4AFFFFFF):
            a, b = value32(bits), value32(bits + 1)
            middle = (a + b) / 2
            for value in (math.nextafter(middle, -math.inf), middle, math.nextafter(middle, math.inf)):
                for sign in (-1, 1):
                    x = value * sign
                    expected, = struct.unpack("<I", struct.pack("<f", x))
                    self.assertEqual(rounded_ratio(*x.as_integer_ratio(), 8, 23), expected)

    def test_half_operations_preserve_ieee_zero_signs(self):
        self.assertEqual(half_product(0x8000, 0x3C00), 0x8000)
        self.assertEqual(half_product(0x8000, 0xBC00), 0)
        self.assertEqual(half_sum(0x8000, 0x8000), 0x8000)
        self.assertEqual(half_sum(0x3C00, 0xBC00), 0)
        self.assertEqual(half_from32(0x80000000), 0x8000)

    def test_exact_half_products_and_sums_against_struct(self):
        rng = random.Random(8421)
        for _ in range(4096):
            a, b = rng.randrange(0x7000), rng.randrange(0x7000)
            x, = struct.unpack("<e", struct.pack("<H", a))
            y, = struct.unpack("<e", struct.pack("<H", b))
            for actual, value in ((half_product(a, b), x * y), (half_sum(a, b), x + y)):
                try:
                    expected, = struct.unpack("<H", struct.pack("<e", value))
                except OverflowError:
                    expected = 0x7C00
                self.assertEqual(actual, expected)

    def test_decimal_trig_crosscheck_and_unresolved_interval(self):
        with localcontext() as context:
            context.prec = 120
            pi = decimal_pi()
            self.assertEqual(float(pi), math.pi)
            freq = frequencies(pi)
            self.assertEqual(len(freq), 32)
            for value in (0, .1, 1, 95, 255, 1535):
                bits = d32(Decimal(str(value)))
                c, s = trig32(bits, pi)
                self.assertEqual(c, d32(Decimal.from_float(math.cos(value32(bits)))))
                self.assertEqual(s, d32(Decimal.from_float(math.sin(value32(bits)))))
            with self.assertRaises(ValueError):
                unambiguous32(Decimal(0))

    def test_identity_rotation_and_shape_rejection(self):
        values = [0x3C00] * 64
        self.assertEqual(rotate(values, [0x3C00] * 32, [0] * 32), values)
        with self.assertRaises(ValueError):
            rotate(values[:-1], [0x3C00] * 32, [0] * 32)


if __name__ == "__main__":
    unittest.main()
