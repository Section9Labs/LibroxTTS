# Q8 semantic V3 qualification

The additive V3 candidate retains the canonical Q8 group-64 weights, native
prefill, canonical two-row decode, mixed accurate activations and F32 head. It
uses the independently certified 1536-position half RoPE table and separate
half-rounded products and sums. V1/V2, their failed oracles and the default
uncompressed profile remain unchanged.

Independent CPU reference qualification completed for six preregistered public
English/Spanish prefixes: short, cache-256 crossing and long prefixes evaluating
positions 494 and later. Full and 64-row-chunk CPU trajectories have identical
logits and active caches. Six fresh GPU processes passed all 54 comparisons
against that independent reference under unchanged maximum absolute error 0.05,
relative L2 0.002 and both-lane top-1 requirements. All 108 lane leaders agree;
maximum absolute error is 0.0137252808 and maximum relative L2 is 0.00135507746.
An independent reviewer verified the raw outputs, reconstructed caches and
source/runtime/artifact bindings.

These results do not establish original FP32 audio equivalence, phone execution,
voice quality, sustained playback, battery benefit or five-times-playback speed.
The original FP32 compression comparison remains 4/18; it is not repointed.

A separate startup artifact consumes only the original frozen 18 fixture inputs,
unchanged, through the qualified independent CPU evaluator with fresh English
and Spanish caches. No GPU-derived targets or injected legacy caches enter it.
It must be frozen before the new runtime profile is evaluated. The old fixture
remains immutable. All 18 new startup gates must pass independently of the 54
holdout comparisons. This avoids running the long, roughly 2 GB peak diagnostic
prefills during phone initialization.

Before any new phone build, qualify the complete watermarked LibroxKit path:
matched Standard/V3 English and Spanish audio, stock and authorized local
reference conditioning, exact text/options/sampling seed/acoustic noise;
finite output/raw peaks, model/profile/conditioning identities; saved-voice
format compatibility; cache, cancellation and voice-change lifecycle; sustained
buffer/underrun and complete-audio RTF measurements. Private phone conditioning
stays on the phone. Matt's listening approval and physical phone validation
remain separate final gates. T3 receives only the exact reviewed library and
artifact contract after these checks, and owns application integration.
