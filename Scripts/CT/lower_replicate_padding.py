#!/usr/bin/env python3
"""Lower replicate padding to exact edge gathers, repeats, and concatenation.

Core ML's pad implementation rejects padding wider than an input dimension;
ONNX edge padding has no such restriction. This matters for short utterances
and prevents specialization of enumerated groups containing short lengths.
No learned values, precision, latent lengths, or masks change.
"""
import argparse, pathlib, json
import numpy as np
import coremltools as ct
from coremltools.converters.mil.frontend.milproto.load import load
from coremltools.converters.mil.converter import mil_convert
from coremltools.converters.mil.mil import Builder as mb

p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('output',type=pathlib.Path)
p.add_argument('--indices',action='store_true');a=p.parse_args()
assert not a.output.exists()
m=ct.models.MLModel(str(a.source),skip_model_load=True);s=m.get_spec()
program=load(s,s.specificationVersion,m.weights_dir);changes=[]
for f in program.functions.values():
    with f:
        for o in list(f.operations):
            if o.op_type!='pad' or o.mode.val!='replicate':continue
            pads=o.pad.val
            assert pads is not None and np.all(pads[:-2]==0) and np.all(pads>=0)
            left,right=map(int,pads[-2:]);rank=len(o.x.shape);parts=[]
            prefix='ct_edge_'+o.name
            if a.indices:
                shape=mb.shape(x=o.x,name=prefix+'_shape',before_op=o)
                length=mb.gather(x=shape,indices=np.int32(rank-1),axis=0,name=prefix+'_length',before_op=o)
                indices=mb.range_1d(start=np.int32(0),end=length,step=np.int32(1),name=prefix+'_range',before_op=o)
                if left:parts.append(np.zeros(left,np.int32))
                parts.append(indices)
                if right:
                    last=mb.sub(x=length,y=np.int32(1),name=prefix+'_index',before_op=o)
                    last=mb.expand_dims(x=last,axes=[0],name=prefix+'_last_vector',before_op=o)
                    tail=mb.tile(x=last,reps=np.array([right],np.int32),name=prefix+'_tail',before_op=o)
                    parts.append(tail)
                indices=mb.concat(values=parts,axis=0,name=prefix+'_indices',before_op=o)
                padded=mb.gather(x=o.x,indices=indices,axis=rank-1,name=prefix+'_padded',before_op=o)
                f.replace_uses_of_var_after_op(o,o.outputs[0],padded,force_replace=True);f.remove_ops([o])
                changes.append({'name':o.name,'left':left,'right':right,'method':'indices'})
                continue
            if left:
                first=mb.gather(x=o.x,indices=np.array([0],np.int32),axis=rank-1,name=prefix+'_first',before_op=o)
                parts.append(mb.tile(x=first,reps=np.array([1]*(rank-1)+[left],np.int32),name=prefix+'_left',before_op=o))
            parts.append(o.x)
            if right:
                shape=mb.shape(x=o.x,name=prefix+'_shape',before_op=o)
                length=mb.gather(x=shape,indices=np.array([rank-1],np.int32),axis=0,name=prefix+'_length',before_op=o)
                last=mb.sub(x=length,y=np.array([1],np.int32),name=prefix+'_index',before_op=o)
                edge=mb.gather(x=o.x,indices=last,axis=rank-1,name=prefix+'_last',before_op=o)
                parts.append(mb.tile(x=edge,reps=np.array([1]*(rank-1)+[right],np.int32),name=prefix+'_right',before_op=o))
            padded=mb.concat(values=parts,axis=rank-1,name=prefix+'_padded',before_op=o)
            f.replace_uses_of_var_after_op(o,o.outputs[0],padded,force_replace=True);f.remove_ops([o])
            changes.append({'name':o.name,'left':left,'right':right})
        for o in f.operations:o.type_value_inference(overwrite_output=True)
out=mil_convert(program,convert_to='mlprogram',convert_from='milinternal',compute_units=ct.ComputeUnit.CPU_ONLY,
    model_description=s.description,specification_version=s.specificationVersion,skip_model_load=True,
    pass_pipeline=ct.PassPipeline(['common::dead_code_elimination']))
a.output.parent.mkdir(parents=True,exist_ok=True);out.save(str(a.output))
a.output.with_suffix('.padding.json').write_text(json.dumps(changes,indent=2)+'\n')
print('Replaced',len(changes),'replicate padding operations')
