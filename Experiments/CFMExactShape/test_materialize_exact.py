import copy
import unittest
from materialize_exact import require_shape_only, SHAPES


class ShapeOnlyTests(unittest.TestCase):
    def fixtures(self):
        def var(name, shape, dtype='fp32'):
            return dict(name=name, shape=shape, dtype=dtype)
        old = dict(inputs={k: var(k, [x if x != 700 else 'T' for x in v]) for k, v in SHAPES.items()},
            outputs=[var('out', [1, 80, 'T'])],
            constants={'weight': dict(dtype='<f4', shape=[2], sha256='original')},
            operators=[dict(name='linear', kind='matmul', inputs={'x': ['x'], 'weight': ['weight']},
                            outputs=[var('out', [1, 80, 'T'])])])
        new = copy.deepcopy(old)
        for value in new['inputs'].values():
            value['shape'] = [700 if x == 'T' else x for x in value['shape']]
        new['outputs'][0]['shape'][-1] = 700
        new['operators'][0]['outputs'][0]['shape'][-1] = 700
        return old, new

    def testExactSpecializationWithoutArithmeticChange(self):
        require_shape_only(*self.fixtures())

    def testLearnedBitsPrecisionAndEdgesCannotChange(self):
        for mutate in [
            lambda d: d['constants']['weight'].update(sha256='changed'),
            lambda d: d['operators'][0]['outputs'][0].update(dtype='fp16'),
            lambda d: d['operators'][0]['inputs'].update(x=['different']),
            lambda d: d['operators'].append(copy.deepcopy(d['operators'][0])),
            lambda d: d['operators'][0].update(kind='cast'),
        ]:
            old, new = self.fixtures(); mutate(new)
            with self.assertRaises(ValueError): require_shape_only(old, new)

    def testPreviouslyStaticOrStillSymbolicDimensionsFail(self):
        for shape in [[2, 80, 700], [1, 80, 'T'], [1, 80, 0], [1, 80, 701]]:
            old, new = self.fixtures(); new['inputs']['x']['shape'] = shape
            with self.assertRaises(ValueError): require_shape_only(old, new)

class MILMaterializationTests(unittest.TestCase):
    def testActualSinglePassRetainsOperationsConstantsAndDtypes(self):
        import coremltools as ct
        import numpy as np
        from coremltools.converters.mil import Builder as mb
        from coremltools.converters.mil.mil import get_new_symbol
        from coremltools.converters.mil.mil.passes.pass_pipeline import PassPipelineManager
        from materialize_exact import describe
        length = get_new_symbol()
        @mb.program(input_specs=[mb.TensorSpec((1, 80, length)), mb.TensorSpec((1, 80, length)),
            mb.TensorSpec((1, 80, length)), mb.TensorSpec((1, 1, length)),
            mb.TensorSpec((1, 192)), mb.TensorSpec((1,)), mb.TensorSpec((1,))],
            opset_version=ct.target.iOS17)
        def program(x, mu, cond, mask, spks_raw, spks_scale, t):
            signal = mb.add(x=mb.add(x=x, y=mu), y=cond)
            return mb.mul(x=mb.mul(x=signal, y=mask), y=np.float32(0.7))
        before = describe(program.functions['main'], np)
        pipeline = ct.PassPipeline(pass_names=['common::materialize_symbolic_shape_program'])
        pipeline.set_options('common::materialize_symbolic_shape_program',
            {'function_name_to_materialization_map': {'main': SHAPES}, 'source_function_name': 'main'})
        PassPipelineManager.apply_pipeline(program, pipeline)
        after = describe(program.functions['main'], np)
        require_shape_only(before, after)


class PublicationTests(unittest.TestCase):
    def testRedirectedPinnedManifestCannotSelectOtherModelOrWeights(self):
        import tempfile, json, hashlib
        from pathlib import Path
        from materialize_exact import resolve_manifest
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            record = {'rootModelIdentifier': 'model', 'itemInfoEntries': {
                'model': {'author': 'com.apple.CoreML', 'name': 'model.mlmodel', 'path': 'com.apple.CoreML/model.mlmodel'},
                'weights': {'author': 'com.apple.CoreML', 'name': 'weights', 'path': 'com.apple.CoreML/weights'}}}
            def save():
                data = json.dumps(record).encode(); (root / 'Manifest.json').write_bytes(data)
                return hashlib.sha256(data).hexdigest()
            original = save(); resolve_manifest(root, original)
            record['itemInfoEntries']['model']['path'] = '../other/model.mlmodel'
            changed = save()
            with self.assertRaises(ValueError): resolve_manifest(root, original)
            with self.assertRaises(ValueError): resolve_manifest(root, changed)
            record['itemInfoEntries']['model']['path'] = 'com.apple.CoreML/model.mlmodel'
            record['itemInfoEntries']['weights']['path'] = '../other/weights'
            changed = save()
            with self.assertRaises(ValueError): resolve_manifest(root, changed)

    def testExpiryDuringFinalHashCannotReturnSuccessManifest(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        from materialize_exact import final_package_files
        state = {'hashed': False}
        def check():
            if state['hashed']: raise TimeoutError('Expired during hashing')
        def hash_file(path, callback):
            callback(); state['hashed'] = True; return 'hash'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / 'weight.bin').write_bytes(b'weights')
            with patch('materialize_exact.digest', hash_file):
                with self.assertRaises(TimeoutError): final_package_files(root, check)


if __name__ == '__main__': unittest.main()
