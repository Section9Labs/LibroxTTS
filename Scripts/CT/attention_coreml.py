"""Exact CT relative-attention algebra using a nine-position lookup.

The source's pad/reshape trick is replaced by explicit relative offsets. No
weights, attention window, masking value, softmax, or projection is changed.
"""
import math
import re
import onnx
import torch
from onnx2torch.node_converters.registry import _CONVERTER_REGISTRY, OperationDescription
from onnx2torch.utils.common import OperationConverterResult, OnnxMapping


class RelativeAttention(torch.nn.Module):
    def __init__(self, weights):
        super().__init__()
        for name, value in weights.items():
            self.register_buffer(name, torch.from_numpy(value.copy()))
        self.dimension = self.rel_k.shape[-1]
        self.channels = self.q_weight.shape[0]
        self.heads = self.channels // self.dimension
        assert self.rel_k.shape == self.rel_v.shape
        assert self.rel_k.shape[0] == 1 and self.rel_k.shape[1] == 9

    def project(self, x, name):
        return torch.nn.functional.conv1d(x, getattr(self, name + '_weight'), getattr(self, name + '_bias'))

    def forward(self, x, mask):
        length = x.shape[-1]
        q = self.project(x, 'q').reshape(1, self.heads, self.dimension, length).transpose(2, 3)
        k = self.project(x, 'k').reshape(1, self.heads, self.dimension, length)
        v = self.project(x, 'v').reshape(1, self.heads, self.dimension, length).transpose(2, 3)
        q = q / math.sqrt(self.dimension)
        positions = torch.arange(length, device=x.device)
        relative = positions.unsqueeze(0) - positions.unsqueeze(1) + 4
        valid = ((relative >= 0) & (relative < 9)).to(x.dtype)
        indexes = torch.clamp(relative, 0, 8).unsqueeze(0).unsqueeze(0).expand(1, self.heads, length, length)
        key_logits = torch.matmul(q, self.rel_k.transpose(1, 2))
        relative_logits = torch.gather(key_logits, -1, indexes) * valid
        logits = torch.matmul(q, k) + relative_logits
        logits = torch.where(mask == 0, -10000., logits)
        probabilities = torch.softmax(logits, dim=-1)
        # For each query, at most one key has each relative offset. Reducing
        # zero-filled selections preserves those values without dynamic padding.
        relative_probabilities = torch.stack([
            torch.sum(probabilities * (relative == offset).to(x.dtype), dim=-1)
            for offset in range(9)
        ], dim=-1)
        output = torch.matmul(probabilities, v) + torch.matmul(relative_probabilities, self.rel_v)
        return self.project(output.transpose(2, 3).reshape(1, self.channels, length), 'o')


def replace_attention(model):
    prefixes = sorted({re.match(r'(.*/attn_layers\.\d+/)', n.name).group(1)
                       for n in model.graph.node if '/attn_layers.' in n.name})
    replacements = {}
    for prefix in prefixes:
        nodes = [n for n in model.graph.node if n.name.startswith(prefix)]
        by_name = {n.name: n for n in nodes}
        q = by_name[prefix + 'conv_q/Conv']
        final = by_name[prefix + 'conv_o/Conv']
        # All layers reuse the same mask; the first layer owns its Equal node.
        encoder_prefix = prefix.split('/attn_layers.')[0]
        mask = encoder_prefix + '/Mul_output_0'
        defined = {out for node in nodes for out in node.output}
        external = {inp for node in model.graph.node if not node.name.startswith(prefix) for inp in node.input}
        allowed = set(final.output) | {out for node in nodes if node.op_type == 'Equal' for out in node.output}
        assert defined.intersection(external) <= allowed, prefix
        weight_prefix = q.input[1].removesuffix('conv_q.weight')
        replacements[prefix] = onnx.helper.make_node('CTAttention', [q.input[0], mask], list(final.output),
            name=prefix + 'CTAttention', domain='librox', weight_prefix=weight_prefix)
    result = []
    inserted = set()
    for node in model.graph.node:
        prefix = next((p for p in prefixes if node.name.startswith(p)), None)
        if prefix is None:
            result.append(node)
        else:
            if prefix not in inserted:
                result.append(replacements[prefix]); inserted.add(prefix)
            if node.op_type == 'Equal':
                result.append(node)
    del model.graph.node[:]
    model.graph.node.extend(result)
    model.opset_import.append(onnx.helper.make_opsetid('librox', 1))
    return model


def attention(node, graph):
    prefix = node.attributes['weight_prefix']
    weights = {'rel_k': graph.initializers[prefix + 'emb_rel_k'].to_numpy(),
               'rel_v': graph.initializers[prefix + 'emb_rel_v'].to_numpy()}
    for letter in ['q', 'k', 'v', 'o']:
        for kind in ['weight', 'bias']:
            weights[letter + '_' + kind] = graph.initializers[prefix + 'conv_' + letter + '.' + kind].to_numpy()
    return OperationConverterResult(RelativeAttention(weights), OnnxMapping(node.input_values, node.output_values))


_CONVERTER_REGISTRY[OperationDescription('librox', 'CTAttention', 1)] = attention
