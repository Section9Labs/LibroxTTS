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

## Runtime and complete-pipeline results

The independently generated original-input reference is SHA256
`d2878e946dfef6f4a0073493b4196a201fa1993fd4551d744d67646ada900d86`.
All 18 startup comparisons pass in the archived V3 runtime, including the
previous Spanish failure. Its bundled table resolves inside the copied
resource bundle. Release checks pass 42 MLX tests plus the 57-case library run
(with three opt-in real-model integrations skipped). This does not clear phone
execution or listening quality.

The first matched full-pipeline run stopped on the **Standard** baseline:
English completed 36.24 seconds of generated audio in 34.993 seconds (RTF 0.966),
then Spanish unit 0 reached `generationLimit` before audio. V3 audio did not run.
The failed run and all English PCM/per-unit progress remain immutable.
Compatible grouping merges up to 300 characters, while the multilingual
frontend retains a hard 350-token generation bound. The failed first Spanish
paragraph has 246 characters and 42 words; this is a hypothesis for the failure,
not proof of causation. The separately registered sentence-control experiment
changes only the existing explicit grouping mode, retaining text, conditioning,
seeds, arithmetic, the 350-token guard, CPU acoustics and watermark. No phone
build is cleared while this full-pipeline issue remains.

## Cache identity after logical tensor access

The logical-layout correction changes the interpretation of valid strided Core
ML tensors. SDK cache adapter revision 4 prevents reuse of audio made under the
previous packed-storage assumption. The native renderer exposes an opaque
`profileIdentifier` that also binds decoder selection, encoder/CFM/vocoder/
watermark compute-unit policies and input-buffer reuse. Hosts should use that
identity or the matching pure `renderingProfileIdentifier` helper, rather than
reconstructing it from `usesQ8Weights` or the legacy decoder-only ID.

Decoder selection strings, weight/oracle hashes and saved voice files remain
unchanged. This invalidates generated-audio identities; it neither migrates
voices nor clears a failed decoder gate. It does not activate GPU/ANE policies.

Subsequent sentence controls completed all eight Standard/V3 English/Spanish,
stock/authorized-reference outputs. V3 complete playback RTF was about1.12–1.32
with derived buffer deficits. Matt slightly preferred Standard's neutral
expression. Matched storyteller outputs also completed; their listening
acceptance remains separate. None of these results clears phone throughput or
the five-times-playback target.
