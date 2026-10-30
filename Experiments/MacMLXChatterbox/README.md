# Offline Mac MLX reference qualification

Production Librox rendering remains Swift-native. These Python scripts are offline checkpoint/implementation qualification tools, not a companion runtime or shipped dependency.

The pinned full-F32 multilingual V3 candidate is `mlx-community/chatterbox-multilingual-v3@03565773edd72e949572557597af8063bb49a18a`; source runtime `Blaizzy/mlx-audio@b80c4edb4181c102f72b56bbf6ce9438a2050354`. The existing Core ML/MLX Swift Standard remains the quality control. No replacement is qualified by model download or this audit.

`weight_audit.py` constructs four components on CPU and requires complete key/shape/dtype coverage and `strict=True` loading after upstream sanitization. It does not invoke a model forward or produce audio. The S3Tokenizer constructor DOES evaluate two Float32[2048,64] RoPE tables (~1MiB) on CPU; this is explicitly permitted in V02 and is not a zero-evaluation claim. A future GPU evaluation must be a fresh process, to avoid CPU compilation-cache/device confounds.

Every component comparison is saved before strict loading, so an exception retains its evidence. No missing/random parameter, unknown tensor, wrong shape or dtype is accepted. All four components must pass. Installed model/interpreter/MLX-Audio/MLX source and native dependencies, host guard, supervisor and lifecycle helper are pinned before and after. The supervisor uses a separately frozen source bundle with copies of `materialize_exact.py` (host guard) and the previously tested `run_assembled_reference.py` lifecycle helper. Running the repository supervisor without such a reviewed frozen bundle intentionally fails.

Bounds: one process, 180 seconds, 8GiB RSS, thermal/low-power/disk/cancellation guards, owned process-group TERM/KILL and join. Success receipt is last. Timeout/failure is terminal with no automatic retry.

V01 is preserved unlaunched: review found implicit constructor evaluation and missing dependency identities. V02 preregistration is `/Volumes/T9.2025/LibroxTraining/runs/chatterbox-quantization-evaluation-v01/mac-mlx-v3-weight-audit-v02-preregistration.json`, SHA `5a5d1cfadb43e66284b0715f6284f34860ac166d2a2aee93f1c290e1506c05eb`. Existing Astra reviewed all1,380fingerprints, constructor scope, source delta and lifecycle before the one launch. Consult that run's durable report, never infer success from these source files.

Focused metadata-gate tests:

```
python3 -m unittest discover -s Experiments/MacMLXChatterbox -p 'test_*.py'
python3 -O -m unittest discover -s Experiments/MacMLXChatterbox -p 'test_*.py'
```

These tests show partial/mismatched metadata fails; they do not certify numerical, waveform, performance, Swift integration or physical-device behavior. The audit is a prerequisite only.

## V02 observed outcome: preserved terminal gate failure

The one V02 run failed strict coverage before a forward. VE13/13 and S3Tokenizer102/102 passed. T3 lacked a generic `tfmr.lm_head.weight`, and its unused generic token embedding was checkpoint[8,1024] versus template[4000,1024]. S3Gen lacked five constructor-owned arrays. No generated audio or performance claim results from this run.

Independent source review confirmed that all three inspected Python T3 paths provide explicit embeddings to the backbone and use T3's trained speech/text heads; this does not turn V02 into a pass. There is no reason to repair/adopt that Python decoder for production: retain the already-qualified Librox Swift decoder.

The five S3 arrays require explicit native synthesis-state contracts, not a permissive missing-weight exception:

- `flow.decoder.rand_noise`: live normal noise[1,80,15000], constructor-global seed0, sliced per call; shape, dtype, key/seed/reset behavior are numerically consequential.
- Both `pos_enc.pe`: live analytical relative-position tables[1,9999,512], centered/sliced/extended as required.
- `mel2wav.stft_window`: live periodic Hann window, length16.
- `trim_fade`: live960sample envelope,480zeros then480sample cosine ramp.

Next finite dependency: strict acoustic-only Swift inventory, tracking EACH raw checkpoint key through remapping, including explicit accepted/dropped reasons and initialized-buffer recipes. Post-sanitization strictness alone is insufficient because upstream sanitizers drop unknown keys. The pinned native regular acoustic candidate is MLX-Audio Swift `d08558975ef219e5ed38c71fe2522cc03167899f`, `MLXAudioCodecs.CausalMaskedDiffWithXvec`. Set `meanflow:false` explicitly (default is Turbo), preserve ten CFG/cosine steps and0.7guidance. Its constructor also evaluates seeded noise. Its full convenience generator normalizes peaks to0.95 and loads permissively; do not inherit those policies or replace Librox's reviewed output handling. Keep cancellation checks before accepting output, because upstream solver cancellation can return a partial trajectory.

After inventory review, run one frozen speech-token/stock-condition trajectory including three trailing silence tokens, exact noise, mel layout, trimming and waveform postprocessing. Use an isolated native Swift probe; Python stays reference-only. No new decoder oracle or broad arithmetic study is needed.
