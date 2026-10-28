# swift-safetensors (vendored)

Source: https://github.com/jkrukowski/swift-safetensors, tag `0.1.1`
(`3852f0bd561071588361c26c49c016d344234c60`). MIT License; see `LICENSE.md`.

Only `Sources/Safetensors` and the license were copied. One change: the
`MLTensor` helpers were annotated `macCatalyst 15.0`, but `MLTensorScalar`
requires Mac Catalyst 18, so Librox's Catalyst build failed. They now read
`macCatalyst 18.0`, matching their `iOS 18.0`. No other source was modified.
Drop this copy when upstream ships the fix.
