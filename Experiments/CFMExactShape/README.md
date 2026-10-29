# Exact-shape CFM investigation

This is an off-phone graph-specialization experiment. It does not select an app
model or execute Core ML predictions. The original CPU model and old failed
GPU/ANE paths remain unchanged.

`materialize_exact.py` pins the original package manifest, model and weights;
resolves the package to those exact files; applies only the symbolic-shape
materialization pass; compares every constant and ordered nonconstant operation,
operand edge and precision before/after serialization; and requires an exact,
single-function 700-frame signature. The convenience materialization helper is
not used because it adds default optimization passes. A structural pass permits
only the separately reviewed CPU trajectory qualification, not acceleration or
audio clearance.

`supervise.py` runs one frozen child in a private process group. It checks
thermal/low-power state, child RSS, free storage and a 600-second deadline while
load/conversion/save calls block. On failure it drains only the owned process
group with the previously tested TERM/KILL helper. Completion is published last.
Freeze the scripts and that helper together; use a new owned output and a
SHA-bound manifest. Never restart a terminal output or repoint an old model.

The isolated Python 3.11/coremltools 9 environment was installed entirely from
existing uv cache at `/tmp/librox-cfm-exact700-v01-venv`; no weights or dependencies
were downloaded. No Torch dependency is needed. Run source checks with:

```sh
/tmp/librox-cfm-exact700-v01-venv/bin/python -m unittest discover -s Experiments/CFMExactShape
/tmp/librox-cfm-exact700-v01-venv/bin/python -O -m unittest discover -s Experiments/CFMExactShape
```

After reviewed structural qualification: separately register 20 original CPU
conditional/unconditional predictions along the existing synthetic 10-step
trajectory, 20 candidate predictions on those fixed inputs, and 20 candidate
closed-loop predictions. Keep the exact Swift Float schedule and CFG0.7 Euler
operations. Require strict CPU identity and save every input/output/state plus
prediction/copy/CFG/update timings. Only then test the new artifact in isolated
GPU and full model-load contexts, followed by actual token-to-PCM plus Perth
comparisons. A 700-frame experiment does not establish arbitrary narration
length support, phone throughput, listening quality, battery benefit or 5× speed.
