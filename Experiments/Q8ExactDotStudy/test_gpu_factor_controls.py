import unittest
from gpu_factor_controls import ARMS, KEYS, PREREG, CERTIFIED, restored_controls, validate_historical, validate_arm_report


class ControlsTests(unittest.TestCase):
    def raw(self):
        return {arm: {key: b"fixed" for key in KEYS} for arm in ARMS}

    def test_prefill_inactive_controls(self):
        self.assertEqual(len(restored_controls(self.raw())), 8)

    def test_each_restored_mismatch_fails_closed(self):
        for arm in (ARMS[1], ARMS[3]):
            for key in (k for k in KEYS if k.startswith("cpu")):
                raw = self.raw()
                raw[arm][key] = b"changed"
                with self.assertRaises(ValueError):
                    restored_controls(raw)

    def test_native_changes_do_not_invalidate_negative_control(self):
        raw = self.raw()
        raw[ARMS[1]]["native.es.prefill"] = b"different policy"
        self.assertTrue(all(restored_controls(raw).values()))

    def test_empty_historical_controls_are_rejected(self):
        with self.assertRaises(ValueError):
            validate_historical(dict(name="unchangedV2", full18=[],
                                     cpu_prefill_replay=[], cpu_offset95_target=[]))

    def test_missing_lane_in_historical_controls_is_rejected(self):
        old = dict(name="unchangedV2",
                   full18=[dict(stem=k.removeprefix("native.")) for k in KEYS if k.startswith("native.")],
                   cpu_prefill_replay=[dict(stage=f"es.decode.{i}", lanes=[{}, {}]) for i in range(3)],
                   cpu_offset95_target=[dict(stage="es.decode.2", lanes=[])])
        with self.assertRaises(ValueError):
            validate_historical(old)

    def report(self):
        return dict(completed=True, production_clearance=False, gpu_only_model_forward=True,
                    arm=ARMS[0], preregistration_sha256=PREREG, certified_diagnostic_sha256=CERTIFIED,
                    comparisons=[dict(condition=k, old_oracle=dict(lanes=[{}, {}]),
                                      certified_diagnostic=dict(lanes=[{}, {}])) for k in sorted(KEYS)])

    def test_duplicate_or_missing_condition_rejected(self):
        for duplicate in (False, True):
            report = self.report()
            removed = report["comparisons"].pop()
            if duplicate:
                report["comparisons"].append(report["comparisons"][0])
            with self.assertRaises(ValueError):
                validate_arm_report(report, ARMS[0])

    def test_wrong_reference_identity_rejected(self):
        for field in ("preregistration_sha256", "certified_diagnostic_sha256"):
            report = self.report()
            report[field] = "unapproved reference"
            with self.assertRaises(ValueError):
                validate_arm_report(report, ARMS[0])


if __name__ == "__main__":
    unittest.main()
