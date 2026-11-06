# Full Core ML v2 tooling

V1 remains a separate historical experiment. The official v2 package has no
external Swift dependencies. ONNX/PyTorch are conversion/reference tools only.

Conversion environment (development tools only):
Python 3.11, torch 2.7.0, torchvision 0.22.0, coremltools 9.0, onnx 1.18.0,
onnxruntime 1.23.1, numpy 1.26.4, onnx2torch 1.5.15, onnxsim 0.4.36.

## Current general GPU build

The official distribution is `plus-coreml-v2-2026-11-06`; see `docs/COREML-V2.md`.
`package_distribution.py` adds license metadata while asserting unchanged graphs
and weights, then creates public assets and a pinned download manifest.

The active SDK manifest is for `CTCoreMLV2GPUAssets`, not the earlier CPU-only
asset identity. Generation remains FP32. CPU text/duration graphs feed the GPU
generator/vocoder; background playback requests CPU instead.

Starting from the earlier verified full-CPU bundle and frozen ONNX fixtures:

```sh
python convert_coreml.py CTAssets Fixtures/en-return-relief text512 --component vector_estimator --flexible --text-capacity 512
python lower_replicate_padding.py text512/vector_estimator.mlpackage indexed/vector_estimator.mlpackage --indices
python materialize_generator_lengths.py indexed/vector_estimator.mlpackage tiny.mlpackage --last 15
python build_general_gpu_generator.py text512/vector_estimator.mlpackage general/vector_estimator.mlpackage --short-functions tiny.mlpackage
python verify_general_gpu.py CTAssets/onnx/vector_estimator.onnx general/vector_estimator.mlpackage Fixtures/en-return-relief shapes.json --short-functions
python package_general_gpu.py CTCoreMLV2Assets general/vector_estimator.mlpackage shapes.json CTCoreMLV2GPUAssets
```

All 431 lengths must pass before packaging. The short fixed functions explicitly
exclude FP16 conversion; the larger functions enumerate exact lengths within
Apple's 128-shape limit. Shared weights remain one blob. Never pad speech latents.
After adopting the verified new pinned manifest, run:

```sh
CT_TEST_ASSETS=/absolute/path/CTCoreMLV2GPUAssets CT_TEST_FIXTURES=/absolute/path/Fixtures swift test --package-path Integrations/CTNative
CT_TEST_ASSETS=/absolute/path/CTCoreMLV2GPUAssets swift test --filter CTIntegrationTests
swift run -c release --package-path Integrations/CTNative ct-native-probe CTCoreMLV2GPUAssets Fixtures NEW_PARITY coreMLGPUHeavy
python run_device_probe.py DEVICE_UDID com.section9labs.LibroxCTCoreMLV2Test NEW_DEVICE_OUTPUT --backend coreMLGPUHeavy
```

The device runner collects parity, repeated timing/memory and varied passage /
CPU-GPU transition reports, then stops its probe. `--phases parity,benchmark`
supports older probes. It does not test actual lock-screen playback. First-use
compilation, model load, first prediction and warm inference must be reported
separately. Full PCM quality still requires listening acceptance.

## Earlier full-CPU conversion (historical)

1. `prepare_reference.py BUNDLE FIXTURES NEW_OUTPUT` verifies the frozen hashes
   and exports unchanged ONNX references and raw fixtures.
2. `convert_coreml.py CTAssets Fixtures/en-return-relief converted --component NAME
   --flexible` converts `text_encoder`, `text_encoder_early`, or `duration_predictor`.
   The exact relative-attention rewrite is automatic for these components.
   Reuse the verified v1 FP32 generator/vocoder unchanged. FP16 is not qualified.
3. `verify_text_shapes.py CTAssets converted Fixtures/en-return-relief text-shapes.json`
   runs 114 length/mask checks.
4. `package_v2.py CTCoreMLAssets converted text-shapes.json CTCoreMLV2Assets`
   verifies v1 hashes and passing receipts, then assembles a new 21-file bundle.
5. Review/copy the new manifest into the v2 SDK resource `CTCoreMLManifest.json`.
   Never adopt new conversion hashes without verification; package metadata can vary.
6. `verify_coreml.py CTCoreMLV2Assets/coreml Fixtures NEW_PARITY_OUTPUT` checks the
   complete trajectory. Neither source assets nor prior evidence are overwritten.

Native validation from this worktree:

```sh
CT_TEST_ASSETS=/absolute/path/CTCoreMLV2Assets swift test --package-path Integrations/CTNative -c release
CT_TEST_ASSETS=/absolute/path/CTCoreMLV2Assets swift test --filter CTIntegrationTests -c release
Integrations/CTNative/.build/release/ct-native-probe CTCoreMLV2Assets Fixtures NEW_OUTPUT coreMLCPU
# Put the model bundle and independently generated Fixtures under Models/ first.
xcodegen generate --spec Examples/CTDeviceProbe/project.yml
```

The signed v2 app is `com.section9labs.LibroxCTCoreMLV2Test`, displaying
**CT Core ML 2**. It can coexist with v1's **CT Native Test**. `--run-fixtures`
runs both clips on launch and saves tensors, WAVs, timing and memory to Documents.
Build Release. Neither probe replaces Libros or accesses its library.

Set `CT_TEST_FIXTURES=/absolute/path/Fixtures` as well to run the additional
traced/untraced parity test. Set `CT_COMPILE_CACHE_ROOT` to a fresh directory for
an explicit cold-cache experiment, then reuse it in a second process. Never
clear unrelated application caches to manufacture a cold result.

`--run-benchmark` launches the production render path with no tensor snapshots
or output export: first render plus five warm repetitions per fixture. It
records synthesis, 24 kHz delivery, physical footprint and thermal state. This
is a repeated inference test, not an energy measurement or prolonged thermal
soak. Reports are in Documents/benchmark-UUID/benchmark.json.

## Earlier restricted accelerator experiments

These do not replace the variable-length v2 bundle:

```sh
python convert_coreml.py CTAssets Fixtures/en-return-relief ENUM_OUTPUT --component vector_estimator --enumerated-fixtures
python benchmark_component.py ENUM_OUTPUT Fixtures/en-return-relief component.json --units CPU_ONLY,CPU_AND_GPU
python verify_coreml.py CTCoreMLV2Assets/coreml Fixtures GPU_PARITY --generator-models ENUM_OUTPUT --generator-units CPU_AND_GPU --repeats 4
python verify_coreml.py CTCoreMLV2Assets/coreml Fixtures CPU_PARITY --repeats 4
python compute_plan.py MODELS plan.json --components vector_estimator --units CPU_AND_NE
python verify_generator_padding.py V1_ARTIFACT_ROOT padding.json --isolate
```

`--enumerated-fixtures` supports only the English/Spanish fixture shape pairs;
it is not a general passage model. `--text-capacity 512 --flexible` is a separate
padding investigation. `benchmark_component.py --fast-prediction` tests Apple's
Infrequent reshape / FastPrediction hints. Failed backends remain in the report.
Compute plans describe anticipated placement, not observed device utilization.

`prepare_gpu_probe.py FROZEN_SDK V2_ARTIFACT_ROOT NEW_SNAPSHOT` verifies the numeric
screening receipts and prepares a distinct, pinned GPU fixture app from the same
native engine from the earlier frozen snapshot. It rejects the current general
runtime, whose function selection differs. It expects `coreml-enumerated-fp32` and
`enumerated-gpu-full-pipeline` under V2_ARTIFACT_ROOT. Build its generated XcodeGen
project in a separate DerivedData directory. The app ID is
`com.section9labs.LibroxCTGPUFixtureTest`; the general v2 SDK and source assets
are unchanged. The source snapshot and per-file hashes accompany this diagnostic.

`--build-number N` assigns the GPU probe's local build number. The probe keeps
the display awake only while its scene is active; it does not change system
Auto-Lock settings. For the current general probe, capture all three phases and
stop the app after each collection:

```sh
python run_device_probe.py DEVICE_UDID BUNDLE_ID NEW_OUTPUT --backend coreMLGPUHeavy
```

For the historical restricted fixture probe, add `--phases parity,benchmark`;
it does not implement the varied-passage phase. The runner waits up to 60 seconds
for an unlocked device, runs parity, the repeated benchmark and varied passages,
copies results, and sends its own test app a termination signal. Completion
means collection succeeded; inspect the numerical report before qualification.
Varied passages exercise seven texts through GPU → CPU → GPU in the foreground;
this is not a lock-screen playback test. Initial compilation and first use of
each function must be reported separately from warm inference.

`coreMLNeuralEngine` is a diagnostic option only. CPU and the general GPU-heavy
candidate pass the documented numerical checks; neither establishes listening
or host lifecycle acceptance. The unchanged heavy graphs failed Neural Engine
planning in v1.
Licenses/provenance remain hashed in the asset bundle; CTTokenizer adapts the
pinned MIT helper. No learned weights changed and no training was performed.
