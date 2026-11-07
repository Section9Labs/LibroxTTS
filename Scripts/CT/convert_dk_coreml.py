#!/usr/bin/env python3
"""Convert only the frozen DK early encoder; no ONNX Runtime prediction.
PyTorch evaluates the encoder for exporter tracing/reference checks only.
Core ML predictions verify the translated graph. This does not render audio
or establish end-to-end or listening equivalence to archived auditions.
"""
import argparse,json,pathlib,time,hashlib
import numpy as np
import onnx,onnxsim,torch,coremltools as ct
from onnx2torch import convert
p=argparse.ArgumentParser();p.add_argument('--trace-only',action='store_true');p.add_argument('assets',type=pathlib.Path);p.add_argument('fixtures',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--component',choices=['text_encoder_early'],default='text_encoder_early');p.add_argument('--flexible',action='store_true');p.add_argument('--enumerated-fixtures',action='store_true');p.add_argument('--text-capacity',type=int);p.add_argument('--attention',action='store_true');p.add_argument('--precision',choices=['fp32','fp16'],default='fp32');a=p.parse_args()
a.flexible = True
manifest_path = a.assets / 'manifest.json'
assert hashlib.sha256(manifest_path.read_bytes()).hexdigest() == 'a7c2685ef1ac72dda6a06839c03639fabffac4fa2cc94c79dc8b7d3413679098'
manifest = json.loads(manifest_path.read_text())
for file in manifest['files']:
    path = a.assets / file['path']
    assert path.stat().st_size == file['bytes']
    assert hashlib.file_digest(path.open('rb'), 'sha256').hexdigest() == file['sha256'], file['path']
torch.set_num_threads(4)
name=a.component;a.attention=a.attention or name in ['text_encoder','text_encoder_early','duration_predictor'];source=a.assets/'onnx'/(name+'.onnx');model=onnx.load(source)
layout=json.loads((a.fixtures/'layout.json').read_text())
def tensor(n):
    spec=layout[n];return np.fromfile(a.fixtures/(n+'.bin'),dtype=spec['dtype']).reshape(spec['shape'])
feed={}
for x in model.graph.input:
    n=x.name
    if n=='current_step': arr=np.array([0],np.float32)
    elif n=='total_step': arr=np.array([10],np.float32)
    else: arr=tensor({'noisy_latent':'initial_latent','text_emb':'text_emb_early','latent':'latent_after_step_9'}.get(n,n))
    feed[n]=arr
onnx.checker.check_model(model)
def pad_text(n,arr):
    if a.text_capacity and n in ['text_ids','text_mask','text_emb']:
        assert a.component == 'vector_estimator' and a.text_capacity >= arr.shape[-1]
        return np.pad(arr,[(0,0)]*(arr.ndim-1)+[(0,a.text_capacity-arr.shape[-1])])
    return arr
feed={n:pad_text(n,v) for n,v in feed.items()}
shapes={n:list(v.shape) for n,v in feed.items()}
if a.flexible:
    for inp in model.graph.input:
        inp.type.tensor_type.shape.dim[0].dim_value=1
    fixed_text={n:list(v.shape) for n,v in feed.items() if a.text_capacity and n in ['text_ids','text_mask','text_emb']}
    simple,ok=onnxsim.simplify(model,overwrite_input_shapes=fixed_text or None,perform_optimization=not a.attention)
else: simple,ok=onnxsim.simplify(model,overwrite_input_shapes=shapes,perform_optimization=not a.attention)
assert ok
if a.attention:
    from attention_coreml import replace_attention
    simple=replace_attention(simple)

# Static padding avoids a traced tolist() graph path. No numeric approximation.
from onnx2torch.node_converters.registry import _CONVERTER_REGISTRY,OperationDescription
from onnx2torch.node_converters.pad import OnnxPadStatic
from onnx2torch.utils.common import OperationConverterResult,OnnxMapping


def pad(node,graph):
    if node.input_values[1] in graph.initializers:
        pads=graph.initializers[node.input_values[1]].to_numpy().flatten().tolist()
        value=float(graph.initializers[node.input_values[2]].to_numpy().reshape(-1)[0]) if len(node.input_values)>2 and node.input_values[2] in graph.initializers else 0.
        module=OnnxPadStatic.create_from_onnx_params(pads,node.attributes.get('mode','constant'),value)
        return OperationConverterResult(module,OnnxMapping((node.input_values[0],),node.output_values))
    raise NotImplementedError('Unconverted dynamic Pad: '+node.name)
for version in [11,13,18,19,21]: _CONVERTER_REGISTRY[OperationDescription('', 'Pad',version)]=pad
# Opset 19 only expands permitted dtypes for these ops; CT uses existing float/int types.
for op,old,new in [('Split',13,18),('ReduceSum',13,18),('Reshape',14,19),('Equal',13,19),('Cast',13,19),('Shape',15,19),('Size',13,19),('Constant',13,19),('AveragePool',11,19),('Identity',14,19)]:
    key=OperationDescription('',op,old)
    if key in _CONVERTER_REGISTRY: _CONVERTER_REGISTRY[OperationDescription('',op,new)]=_CONVERTER_REGISTRY[key]
class Clip(torch.nn.Module):
    def forward(self,x,lo=None,hi=None):
        if lo is not None:x=torch.maximum(x,lo)
        if hi is not None:x=torch.minimum(x,hi)
        return x
for version in [11,12,13]:
    _CONVERTER_REGISTRY[OperationDescription('', 'Clip',version)]=lambda node,graph: OperationConverterResult(Clip(),OnnxMapping(node.input_values,node.output_values))
class Shape(torch.nn.Module):
    def __init__(self,start=0,end=None):super().__init__();self.start=start;self.end=end
    def forward(self,x):return torch._shape_as_tensor(x)[self.start:self.end]
if a.flexible:
    for version in [1,13,15,19]:
        _CONVERTER_REGISTRY[OperationDescription('', 'Shape',version)]=lambda node,graph: OperationConverterResult(Shape(node.attributes.get('start',0),node.attributes.get('end')),OnnxMapping(node.input_values,node.output_values))
class Less(torch.nn.Module):
    def forward(self,x,y):return x < y
for version in [7,9,13]:
    _CONVERTER_REGISTRY[OperationDescription('', 'Less',version)]=lambda node,graph: OperationConverterResult(Less(),OnnxMapping(node.input_values,node.output_values))
# The generic Max translator materializes an empty scalar broadcast shape.
# Pairwise maximum has identical ONNX broadcasting semantics and exports natively.
class ElementwiseMaximum(torch.nn.Module):
    def forward(self, first, second):
        return torch.maximum(first, second)
for version in [8, 12, 13]:
    _CONVERTER_REGISTRY[OperationDescription('', 'Max', version)] = lambda node, graph: OperationConverterResult(ElementwiseMaximum(), OnnxMapping(node.input_values, node.output_values))
module=convert(simple).eval()
inputs=tuple(torch.from_numpy(feed[x.name].copy()) for x in simple.graph.input)
with torch.inference_mode():
    expected=module(*inputs).numpy();traced=torch.jit.trace(module,inputs,check_trace=False)
    actual=traced(*inputs).numpy()
def metrics(x,y):
 d=x.astype(np.float64)-y.astype(np.float64);return {'maxAbsoluteError':float(abs(d).max()),'rmse':float(np.sqrt(np.mean(d*d))),'snrDB':float(10*np.log10(np.sum(y.astype(np.float64)**2)/np.sum(d*d))) if np.any(d) else 999}
report={'component':name,'precision':a.precision,'textCapacity':a.text_capacity,'shapes':shapes,'traceAgainstExportGraph':metrics(actual,expected),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'sourceManifestSHA256':hashlib.sha256(manifest_path.read_bytes()).hexdigest(),'onnxRuntimePredictions':0,'scope':'Encoder translation check against export graph; not audio or listening equivalence'}
if a.flexible:
    alt=a.fixtures.parent/'es-return-dread';altLayout=json.loads((alt/'layout.json').read_text())
    alternate={}
    for n in feed:
        key={'noisy_latent':'initial_latent','text_emb':'text_emb_early','latent':'latent_after_step_9'}.get(n,n)
        if key not in altLayout:alternate[n]=feed[n];continue
        spec=altLayout[key];alternate[n]=np.fromfile(alt/(key+'.bin'),dtype=spec['dtype']).reshape(spec['shape'])
    alternate={n:pad_text(n,v) for n,v in alternate.items()}
    altInputs=tuple(torch.from_numpy(alternate[x.name].copy()) for x in simple.graph.input)
    with torch.inference_mode():
        altExpected=module(*altInputs).numpy()
        report['alternateTorch']=metrics(module(*altInputs).numpy(),altExpected)
        report['alternateTrace']=metrics(traced(*altInputs).numpy(),altExpected)
    assert report['alternateTrace']['maxAbsoluteError'] < 0.001,report
print(report,flush=True)
a.output.mkdir(parents=True,exist_ok=True)
# onnx2torch's real-valued shape constants trace numpy's conjugate resolution;
# all CT tensors are real, so these two operations are identities.
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
@register_torch_op
def resolve_conj(context,node):context.add(context[node.inputs[0]],node.name)
@register_torch_op
def resolve_neg(context,node):context.add(context[node.inputs[0]],node.name)
textRange=ct.RangeDim(lower_bound=8,upper_bound=512,default=192,symbol='text_length')
latentRange=ct.RangeDim(lower_bound=1,upper_bound=431,default=178,symbol='latent_length')
def mlshape(n,v):
    if not a.flexible:return v.shape
    if a.enumerated_fixtures and alternate[n].shape != v.shape:
        return ct.EnumeratedShapes(shapes=[v.shape,alternate[n].shape],default=v.shape)
    shape=list(v.shape)
    if n in ['text_ids','text_mask','text_emb'] and not a.text_capacity:shape[-1]=textRange
    if n in ['noisy_latent','latent_mask','latent']:shape[-1]=latentRange
    return tuple(shape)
if a.trace_only:
    traced.save(str(a.output/'dk-encoder-export-trace.pt'))
    raise SystemExit(0)
ml=ct.convert(traced,convert_to='mlprogram',minimum_deployment_target=ct.target.iOS18,
 inputs=[ct.TensorType(name=n,shape=mlshape(n,v),dtype=np.int32 if v.dtype==np.int64 else np.float32) for n,v in feed.items()],
 outputs=[ct.TensorType(name=simple.graph.output[0].name,dtype=np.float32)],
 compute_precision=ct.precision.FLOAT32 if a.precision=='fp32' else ct.precision.FLOAT16,compute_units=ct.ComputeUnit.CPU_ONLY,skip_model_load=True)
if a.text_capacity:ml.user_defined_metadata['ct.textCapacity']=str(a.text_capacity)
ml.save(str(a.output/(name+'.mlpackage')))
print('SAVED; loading model',flush=True)
ml=ct.models.MLModel(str(a.output/(name+'.mlpackage')),compute_units=ct.ComputeUnit.CPU_ONLY)
start=time.time();out=ml.predict({n:v.astype(np.int32) if v.dtype==np.int64 else v for n,v in feed.items()})
report['coreml']=metrics(next(iter(out.values())),expected);report['seconds']=time.time()-start
assert np.isfinite(next(iter(out.values()))).all()
assert report['coreml']['maxAbsoluteError'] < 0.001, report
if a.flexible:
    altOut=ml.predict({n:v.astype(np.int32) if v.dtype==np.int64 else v for n,v in alternate.items()})
    report['alternateCoreML']=metrics(next(iter(altOut.values())),altExpected)
    assert report['alternateCoreML']['maxAbsoluteError'] < 0.001,report
(a.output/(name+'-conversion.json')).write_text(json.dumps(report,indent=2)+'\n');print(report,flush=True)
