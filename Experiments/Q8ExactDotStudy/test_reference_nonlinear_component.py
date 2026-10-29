from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from reference_nonlinear_component import validate_report, analyze, RAW_SHA, PREREG, softmax32


class ComponentTests(unittest.TestCase):
    def test_exact_resolver_at_known_float32_midpoint(self):
        # The Swift interval deliberately cannot decide this row. Exact sigmoid
        # curvature places its second probability just below the upper midpoint.
        self.assertEqual(softmax32([0, 0x34000000]), [0x3EFFFFFF, 0x3F000000])

    def report(self):
        return dict(completed=True, production_clearance=False, assembled_reference_clearance=False,
                    fixture_sha256=RAW_SHA, preregistration_sha256=PREREG, certified_bit_mismatches=0,
                    rows=[dict(layer=i, head=j) for i in range(30) for j in range(32)])

    def test_bad_membership_or_identity_rejected(self):
        for field in ("fixture_sha256", "preregistration_sha256"):
            r = self.report(); r[field] = "unfrozen"
            with self.assertRaises(ValueError):
                validate_report(r)
        for mode in ("missing", "duplicate"):
            r = self.report(); r["rows"].pop()
            if mode == "duplicate":
                r["rows"].append(r["rows"][0])
            with self.assertRaises(ValueError):
                validate_report(r)

    def test_wrong_preregistration_before_health_or_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); prereg = root / "prereg"
            prereg.write_text("{}")
            with patch("reference_nonlinear_component.Budget") as budget:
                with self.assertRaises(ValueError):
                    analyze(root / "fast", root / "op", root / "primitive", prereg, root / "output", "badsha")
                budget.assert_not_called()
            self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
