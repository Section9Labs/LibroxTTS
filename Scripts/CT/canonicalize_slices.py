#!/usr/bin/env python3
"""Canonicalize masked slice bounds on known axes without changing selected values."""
import argparse,json,pathlib
import numpy as np
import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load
from coremltools.converters.mil.converter import mil_convert
from coremltools.converters.mil.mil import Builder as mb
p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args()
assert not a.output.exists()
model=ct.models.MLModel(str(a.source),skip_model_load=True);spec=model.get_spec()
program=load(spec,spec.specificationVersion,model.weights_dir);changes=[]
for function in program.functions.values():
 with function:
  for op in list(function.operations):
   if op.op_type!='slice_by_index' or op.end.val is None or op.end_mask is None or op.end_mask.val is None:continue
   end=op.end.val.copy();mask=op.end_mask.val.copy();axes=[]
   for axis,size in enumerate(op.x.shape):
    if mask[axis] and isinstance(size,(int,np.integer)):
     end[axis]=size;mask[axis]=False;axes.append(axis)
   if axes:
    op.set_inputs(end=mb.const(val=end,name='ct_canonical_'+op.name+'_end',before_op=op),end_mask=mb.const(val=mask,name='ct_canonical_'+op.name+'_mask',before_op=op))
    changes.append({'name':op.name,'axes':axes,'end':end.tolist(),'endMask':mask.tolist()})
result=mil_convert(program,convert_to='mlprogram',convert_from='milinternal',compute_units=ct.ComputeUnit.CPU_ONLY,model_description=spec.description,specification_version=spec.specificationVersion,skip_model_load=True,pass_pipeline=ct.PassPipeline.EMPTY)
a.output.parent.mkdir(parents=True,exist_ok=True);result.save(str(a.output))
a.output.with_suffix('.changes.json').write_text(json.dumps(changes,indent=2)+'\n')
print('Canonicalized',len(changes),'slices')
