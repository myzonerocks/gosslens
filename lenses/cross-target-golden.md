# Cross-target golden frame

One fixed grade over one fixed synthetic frame, reduced to an 8x8 grid of RGB block means:
192 bytes, hex, one line. Regenerate with `zig build conformance -- --golden`.

Block means rather than pixels, because a per-pixel compare across two backends measures
rasterisation and this measures colour. Clients hold themselves to it within 8/255, the same bar
the iOS look-parity gate uses.
