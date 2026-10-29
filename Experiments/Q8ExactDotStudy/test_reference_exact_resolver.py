import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from reference_exact_resolver import resolve


class ResolverTests(unittest.TestCase):
    class Budget:
        def __init__(self):
            self.began = time.monotonic()
        def check(self):
            pass

    def run_request(self, requests, remaining=180):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source, target = root / "request.json", root / "response.json"
            request = dict(schema=1, id="00000000-0000-0000-0000-000000000001",
                           remaining_seconds=remaining, requests=requests)
            source.write_text(json.dumps(request))
            with patch("reference_exact_resolver.Budget", self.Budget):
                resolve(source, target)
            return json.loads(target.read_text())

    def test_genuine_overwide_dot_and_midpoint_softmax(self):
        result = self.run_request([
            dict(kind="dot", left=[0x7F7FFFFF, 0xFF7FFFFF, 1], right=[0x3F800000] * 3, output="f32"),
            dict(kind="softmax", scores=[0, 0x34000000]),
            dict(kind="dot", left=[0x33000000], right=[0x3F800000], output="f16"),
            dict(kind="dot", left=[0xB3000000], right=[0x3F800000], output="f16")])
        self.assertEqual([r["bits"] for r in result["results"]], [[1], [0x3EFFFFFF, 0x3F000000], [0], [0x8000]])

    def test_partial_failure_never_writes_a_response(self):
        for invalid in [dict(kind="unknown"), dict(kind="softmax", scores=[0x7F800000]),
                        dict(kind="dot", left=[0], right=[], output="f32")]:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); source, target = root / "request", root / "response"
                request = dict(schema=1, id="00000000-0000-0000-0000-000000000001", remaining_seconds=180,
                               requests=[dict(kind="softmax", scores=[0, 0]), invalid])
                source.write_text(json.dumps(request))
                with patch("reference_exact_resolver.Budget", self.Budget):
                    with self.assertRaises(ValueError):
                        resolve(source, target)
                self.assertFalse(target.exists())

    def test_shared_deadline_stops_before_response(self):
        class Expired(self.Budget):
            def __init__(self):
                self.began = time.monotonic() - 2
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source, target = root / "request", root / "response"
            source.write_text(json.dumps(dict(schema=1, id="00000000-0000-0000-0000-000000000001",
                remaining_seconds=0.5, requests=[dict(kind="softmax", scores=[0, 0])])) )
            with patch("reference_exact_resolver.Budget", Expired):
                with self.assertRaises(ValueError):
                    resolve(source, target)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
