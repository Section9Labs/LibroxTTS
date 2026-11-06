#!/usr/bin/env python3
"""Lower CT's unit-stride slices to gathers so variable-length axes stay explicit."""
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
   if op.op_type!='slice_by_index':continue
   rank=len(op.x.shape);begin=op.begin.val
   assert begin is not None and np.all(begin>=0)
   stride=op.stride.val if op.stride is not None else np.ones(rank)
   assert np.all(stride==1)
   beginMask=op.begin_mask.val if op.begin_mask is not None else np.zeros(rank,dtype=bool)
   endMask=op.end_mask.val if op.end_mask is not None else np.zeros(rank,dtype=bool)
   squeeze=op.squeeze_mask.val if op.squeeze_mask is not None else np.zeros(rank,dtype=bool)
   value=op.x
   for axis,size in enumerate(op.x.shape):
    start=0 if beginMask[axis] else int(begin[axis])
    if start==0 and endMask[axis] and not squeeze[axis]:continue
    name='ct_gather_'+op.name+'_'+str(axis)
    if squeeze[axis]:indices=np.array([start],np.int32)
    else:
     if endMask[axis]:
      assert isinstance(size,(int,np.integer));end=int(size)
     elif op.end.val is not None:end=int(op.end.val[axis])
     else:end=mb.gather(x=op.end,indices=np.int32(axis),axis=0,name=name+'_bound',before_op=op)
     if isinstance(end,int):
      assert end>=start
      indices=np.arange(start,end,dtype=np.int32)
     else:indices=mb.range_1d(start=np.int32(start),end=end,step=np.int32(1),name=name+'_indices',before_op=op)
    value=mb.gather(x=value,indices=indices,axis=axis,name=name,before_op=op)
   if np.any(squeeze):value=mb.squeeze(x=value,axes=np.flatnonzero(squeeze).astype(np.int32),name='ct_gather_'+op.name+'_squeeze',before_op=op)
   function.replace_uses_of_var_after_op(op,op.outputs[0],value,force_replace=True)
   function.remove_ops([op]);changes.append(op.name)
result=mil_convert(program,convert_to='mlprogram',convert_from='milinternal',compute_units=ct.ComputeUnit.CPU_ONLY,model_description=spec.description,specification_version=spec.specificationVersion,skip_model_load=True,pass_pipeline=ct.PassPipeline.EMPTY)
a.output.parent.mkdir(parents=True,exist_ok=True);result.save(str(a.output))
a.output.with_suffix('.changes.json').write_text(json.dumps(changes,indent=2)+'\n')
print('Lowered',len(changes),'slices')
