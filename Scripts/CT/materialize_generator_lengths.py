#!/usr/bin/env python3
"""Materialize very short lengths while explicitly preserving FP32 arithmetic."""
import argparse, pathlib
import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load
from coremltools.converters.mil.converter import mil_convert
from coremltools.converters.mil.mil import types
from coremltools.converters.mil.mil.passes.pass_pipeline import PassPipelineManager

p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('output',type=pathlib.Path)
p.add_argument('--last',type=int,default=15);a=p.parse_args();assert not a.output.exists()
m=ct.models.MLModel(str(a.source),skip_model_load=True);s=m.get_spec();program=load(s,s.specificationVersion,m.weights_dir)
pipeline=ct.PassPipeline(['common::materialize_symbolic_shape_program','common::const_elimination','common::dead_code_elimination'])
pipeline.set_options('common::materialize_symbolic_shape_program',{
    'function_name_to_materialization_map':{f'latent_{n}':{'noisy_latent':(1,144,n),'latent_mask':(1,1,n)} for n in range(1,a.last+1)},
    'source_function_name':'main'})
PassPipelineManager.apply_pipeline(program,pipeline)
del program.functions['main']
assert all(v.dtype != types.fp16 for f in program.functions.values() for o in f.operations for v in o.outputs)
program.export_as_multifunction=True;program.default_function_name='latent_1'
out=mil_convert(program,convert_to='mlprogram',convert_from='milinternal',specification_version=s.specificationVersion,
    compute_units=ct.ComputeUnit.CPU_ONLY,skip_model_load=True,pass_pipeline=ct.PassPipeline.EMPTY)
a.output.parent.mkdir(parents=True,exist_ok=True);out.save(str(a.output))
print(a.output,flush=True)
