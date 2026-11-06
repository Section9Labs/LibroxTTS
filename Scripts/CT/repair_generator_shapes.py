#!/usr/bin/env python3
"""Preserve known dimensions lost by the ONNX Expand -> torch -> MIL lowering.

Experiment for the pinned CT generator. No weights or arithmetic are changed.
The ONNX expand shape [1, -1, textLength] becomes [1, 1, textLength] before
ones/broadcast multiplication. A dynamic select hides its constant axes from
Core ML. textLength is positive throughout this model's declared input domain.
"""
import argparse
import json
import pathlib
import numpy as np
import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load
from coremltools.converters.mil.converter import mil_convert
from coremltools.converters.mil.mil import Builder as mb

p = argparse.ArgumentParser()
p.add_argument('source', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path)
a = p.parse_args()
assert not a.output.exists()
m = ct.models.MLModel(str(a.source), skip_model_load=True)
s = m.get_spec()
program = load(s, s.specificationVersion, m.weights_dir)
f = program.functions['main']
ops = {o.name: o for o in f.operations}
op = ops['op_1088']
assert op.op_type == 'select'
assert list(op.a.val) == [1, 1, 1]
assert list(op.b.sym_val[:2]) == [1, -1]
assert op.cond.op.op_type == 'equal'
assert list(op.cond.op.y.val) == [-1, -1, -1]
assert f.inputs['text_emb'].shape[:2] == (1, 256)
with f:
    shape = mb.shape(x=f.inputs['text_emb'], name='ct_text_shape', before_op=op)
    length = mb.gather(x=shape, indices=np.array([2], np.int32), axis=0,
                       name='ct_text_length', before_op=op)
    exact = mb.concat(values=[np.array([1, 1], np.int32), length], axis=0,
                      name='ct_expand_shape', before_op=op)
    f.replace_uses_of_var_after_op(op, op.outputs[0], exact, force_replace=True)
    f.remove_ops([op])
    for index in range(87, 102, 2):
        reshape = ops[f'input_tensor_{index}']
        assert reshape.op_type == 'reshape' and reshape.x.shape[-1] == 512
        reshape.set_inputs(shape=mb.const(val=np.array([2, -1, 8, 64], np.int32),
                           name=f'ct_attention_shape_{index}', before_op=reshape))
    for operation in f.operations:
        operation.type_value_inference(overwrite_output=True)
result = mil_convert(program, convert_to='mlprogram', convert_from='milinternal',
    compute_units=ct.ComputeUnit.CPU_ONLY, model_description=s.description,
    specification_version=s.specificationVersion, skip_model_load=True,
    pass_pipeline=ct.PassPipeline.DEFAULT)
a.output.parent.mkdir(parents=True, exist_ok=True)
result.save(str(a.output))
print(json.dumps({'output':str(a.output), 'expandShape':[1,1,'textLength'],
                  'attentionShape':[2,-1,8,64]}))
