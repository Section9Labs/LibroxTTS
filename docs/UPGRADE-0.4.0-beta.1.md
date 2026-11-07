# Upgrade to LibroxTTS 0.4.0-beta.1

Pin exact `0.4.0-beta.1` in every SwiftPM graph and regenerate the XcodeGen project.
Resolve the tag to one immutable commit everywhere, including validation tools and
pin-check scripts. Stable 0.3.0 uses the previous CT bank and lacks these APIs.

## Model download

The public asset release is
[plus-dk-coreml-preview-v2](https://github.com/Section9Labs/LibroxTTS/releases/tag/plus-dk-coreml-preview-v2).
Identity `librox-plus-dk-coreml-v2` contains 32 pinned files/442,398,406 bytes. Users
with the released CT F1 bank can reuse 403,528,597 verified bytes; 38,869,809 bytes
are changed/new. All ten styles are included; changing language never needs a
separate style download. Unchanged graphs and F1/M1 files match the accepted DK
candidate. The current platform-only changes add no further model bytes.

Use SDK manifests and URLs, not a mutable latest download. Retain the model license,
restrictions and modification notice. Host credentials are not required. Keep
model bytes out of the app binary and source Git history.

Keep the old installation/receipt during download, cancellation and failure. Stage
privately, verify, prepare, then atomically install the new identity. Offer Update
separately from selecting the existing ready F1 voice. Reuse checks actual file
hashes; the displayed incremental size is an estimate if files are missing/corrupt.
The retained runtime explicitly supports old F1 only; new voices/casts require DK.
Never silently replace a requested voice or switch models. See the retained
installation contract in [SHARED-DELIVERY-UPGRADE.md](SHARED-DELIVERY-UPGRADE.md).

## Shared behavior

All 31 Plus languages have persistent casts, manual character/narrator choices,
localized literal speech tags, stage directions and spoken-reading overrides.
Basic uses its own eight-language synthesis catalog and the same shared platform.
Preserve Automatic language, all ten style choices, exact source ranges and the
existing shared voice-card/list/waveform interface. `BookVoiceCast.Language` stores
a language code; phoneme callers explicitly unwrap `pronunciationLanguage`.

`SpokenTextLexicon` is Codable and has a deterministic cache identity. The app's
book overrides precede global overrides in playback, preparation and previews.
Edits replan at the saved reading position; paused playback stays paused. The
original printed text and highlighting offsets never become the spoken rewrite.

Native blending is an optional 80/20 same-group style pairing; off restores the
original style tables. Expression remains unsupported/default-off for native:
latest comparative feedback says context is in the right direction but not a
meaningful improvement. Keep the accepted native baseline intact. Native semantic
seam timing is an explicit opt-in; Basic's existing timing remains unchanged.

Snapshot installation identity when a playback generation is planned, pass it to
`NarrationRenderer.load`, and include it in PCM keys. Keep the snapshot through
background backend switches; a new installation must not replace a model halfway
through an existing generation. Use the model's 44.1kHz/24kHz sample rate, fixed
native dynamics and 1x time-pitch bypass. Cache raw PCM before seam timing; retain
bounded opening/resume reserves and cancellation/lifetime rules.

## Evidence and limits

Full SDK release tests pass, including the retained CT native runtime check.
All 31 languages rendered native blend trials with all ten styles represented;
turning blending off restored exact original PCM with supplied noise. Earlier
all 31 character renders and all-ten EN/ES voice renders remain separately traced.
App correction persistence tests cover all 31, and the isolated iOS build and
update/retry/preview tests are recorded in the release handoff.

These tests do not certify pronunciation, naturalness or expression in every
voice/language. Chinese remains Basic-only. Native dialect, phoneme-dictionary
parity and meaningful expression work remain open. Remaining dedicated hardware
checks are deferred by Matt to TestFlight; no new physical passes are invented.
This SDK release alone is not TestFlight availability. The Release Manager owns
the combined app cut, upload and Apple tester-group verification.
