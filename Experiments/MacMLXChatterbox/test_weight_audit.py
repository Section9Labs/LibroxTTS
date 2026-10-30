import unittest
from weight_audit import compare_specs


class CoverageTests(unittest.TestCase):
    def test_partial_loading_cannot_pass(self):
        expected = {'layer.weight': {'shape': [4, 4], 'dtype': 'float32'},
                    'head.weight': {'shape': [8, 4], 'dtype': 'float32'}}
        missing = compare_specs(expected, {'layer.weight': expected['layer.weight']})
        self.assertFalse(missing['passed'])
        self.assertEqual(missing['missing'], ['head.weight'])
        extra = compare_specs(expected, {**expected, 'foreign.weight': expected['layer.weight']})
        self.assertFalse(extra['passed'])
        self.assertEqual(extra['unexpected'], ['foreign.weight'])
        shape = compare_specs(expected, {**expected, 'head.weight': {'shape': [8, 8], 'dtype': 'float32'}})
        self.assertFalse(shape['passed'])
        dtype = compare_specs(expected, {**expected, 'head.weight': {'shape': [8, 4], 'dtype': 'float16'}})
        self.assertFalse(dtype['passed'])
        self.assertTrue(compare_specs(expected, dict(reversed(list(expected.items()))))['passed'])


if __name__ == '__main__':
    unittest.main()
