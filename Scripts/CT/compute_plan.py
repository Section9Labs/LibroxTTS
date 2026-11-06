#!/usr/bin/env python3
"""Record Core ML's anticipated device placement, not hardware utilization counters."""
import argparse, collections, json, pathlib
import coremltools as ct
from coremltools.models.compute_plan import MLComputePlan

p=argparse.ArgumentParser()
p.add_argument('models',type=pathlib.Path)
p.add_argument('output',type=pathlib.Path)
p.add_argument('--units',choices=['CPU_ONLY','CPU_AND_GPU','CPU_AND_NE','ALL'],default='CPU_AND_GPU')
p.add_argument('--components',default='duration_predictor,text_encoder_early,text_encoder,vector_estimator,vocoder')
a=p.parse_args()
assert not a.output.exists()
reports={}
for name in a.components.split(','):
    try:
        units=getattr(ct.ComputeUnit,a.units)
        model=ct.models.MLModel(str(a.models/(name+'.mlpackage')),compute_units=units)
        plan=MLComputePlan.load_from_path(model.get_compiled_model_path(),compute_units=units)
        counts=collections.Counter();costs=collections.Counter();rows=[]
        def visit(block):
            for op in block.operations:
                usage=plan.get_compute_device_usage_for_mlprogram_operation(op)
                cost=plan.get_estimated_cost_for_mlprogram_operation(op)
                device=type(usage.preferred_compute_device).__name__ if usage else 'unknown'
                counts[device]+=1
                if cost:costs[device]+=cost.weight
                rows.append({'operation':op.operator_name,'outputs':[v.name for v in op.outputs],
                             'preferred':device,'estimatedCost':cost.weight if cost else None})
                for child in op.blocks:visit(child)
        for function in plan.model_structure.program.functions.values():visit(function.block)
        reports[name]={'preferredOperationCounts':dict(counts),'estimatedCostByDevice':dict(costs),'operations':rows}
        print(name,dict(counts),dict(costs),flush=True)
    except Exception as error:
        reports[name]={'error':str(error)}
        print(name,'ERROR',str(error),flush=True)
    a.output.write_text(json.dumps({'computeUnits':a.units,'models':reports},indent=2)+'\n')
