# Optional approved Round 07 expression generation

The separately versioned librox-plus-dk-expression-round07-v1 installation is a
modified derivative of the DK model described in MODIFICATIONS.md. It retains the
complete model and helper licenses and all original voice tables. No endorsement
by Supertone is implied. No learned weight values are added or changed here.

It adds Core ML context-query and spoken-context graphs with centered context
conditioning, quote exclusion, terminal protection, narrator-owned role pooling,
and conservative attached-reporting evidence. The SDK carries the accepted early
conditioning residual into generator updates 3 and 4 at two-thirds and one-third;
updates 5 through 9 retain the original late conditioning. All ten updates, native
duration and full native audio buffers are preserved. Narrator units remain isolated.

This generation contains only cumulative approved Round 07 behavior. Rejected
Rounds 08–10 and later research are excluded. Approval covers the presented F1/M1
English/Spanish comparisons, not all voices/languages or general emotional control.
