# Default Max narration levels at the facade boundary

Status: implemented candidate; user authorized default-level change, listening pending.
Date: 2026-11-12.

Max character voices have materially different loudness on the same neutral text.
The request initially preserved audio, then explicitly authorized changing default
Max dialogue levels. Raw Pocket engine contracts must still preserve exact samples.

Apply a frozen gain per published voice, language and reference style in
`NarrationRenderer`, for narrator and dialogue alike. Keep calibration and its
revision package-scoped in `KokoroNarration`. Derive gains offline from three
passages; assess separate held-out passages. Include gain bits, policy and pinned
manifests in the prepared-audio delivery revision. Raw engines and asset identities
remain unchanged.

A voice-only table would incorrectly transfer Original reference levels to other
performances. Per-sentence normalization would depend on sentence length and pauses,
flatten intentional dynamics and require lookahead or different streaming behavior.
Host-side normalization would duplicate SDK voice policy and cache invalidation.
A new public opt-in policy would not fulfill the authorized default change.

The chosen transform has constant gain through ordinary speech. It has a continuous,
memoryless emergency knee for boosted peaks above amplitude 0.9, preserving frame
partition equivalence and avoiding sample clipping without a lookahead buffer.
The corpus report identifies any activation; this is not a claim of a true-peak
brickwall limiter. Future profile/policy changes require another delivery revision.

Consequences: existing clients gain balanced default Max facade output after
prepared-cache invalidation; direct engine clients retain raw output. Some voices
become quieter and others louder. Sampling, text, timing, events and expressive
shape remain unchanged apart from peak safety. Technical qualification cannot
replace listening acceptance, and a finite corpus cannot bound every future sentence.
