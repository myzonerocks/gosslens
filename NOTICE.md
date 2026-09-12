# Notices

Gosslens
Copyright 2026 Webster Avosa, MyZoneRocks

Licensed under the Apache License, Version 2.0. See [LICENSE.md](LICENSE.md).

## Third-Party Notices

Gosslens includes and depends on third-party software.

Third-party components retain their own copyright, license, attribution, and
other applicable terms. Nothing in the Gosslens license changes or replaces
the terms under which those components are provided.

Third-party source currently present under `third_party/` includes:

- Abseil
- ANGLE
- bgfx
- bimg
- bx
- cgltf
- cpuinfo
- Eigen
- Emscripten
- Emscripten Python tooling
- FarmHash
- fft2d
- FlatBuffers
- FP16
- FXdiv
- gemmlowp
- GLFW
- GPUPixel
- Jolt Physics
- libyuv
- LiteRT
- miniaudio
- ml_dtypes
- neon2sse
- pthreadpool
- QuickJS-ng
- ruy
- TensorFlow
- XNNPACK

Some vendored trees bundle their own third-party components, and Gosslens
builds several of those into its artifacts. They are third-party software
in the same sense as the list above:

- Inside bgfx (shader toolchain, built as a host tool): fcpp (BSD-style),
  glsl-optimizer (MIT), glslang (BSD-3/MIT/Apache-2.0), Khronos headers,
  SPIRV-Cross (Apache-2.0), SPIRV-Headers (MIT/Khronos),
  SPIRV-Tools (Apache-2.0)
- Inside bimg (built into the renderer's image path): astc-encoder
  (Apache-2.0), iqa (BSD), lodepng (Zlib), tinyexr (BSD-3)
- Inside GPUPixel (built into the effects library): ghc filesystem (MIT),
  stb (public domain / MIT); GPUPixel's color conversion links the
  repository's own pinned libyuv rather than the copy bundled in its tree
- Inside TensorFlow (built into the inference runtime): XLA (Apache-2.0)
- Inside the Jolt Physics repository: sample assets under Assets/ carry
  their own proprietary licenses and are never built into or
  distributed with Gosslens artifacts; only the MIT-licensed Jolt/
  sources compile

Model and test assets fetched by `zig build fetch-models` are third-party
material as well, recorded with their licenses in `third_party/models.lock`:
MediaPipe task models (Apache-2.0) and public-domain NASA portrait
photographs used as the conformance corpus.

The Zig compiler is also part of the Gosslens development toolchain and is
provided under its own license.

A component appearing in this repository does not place its code under the
Gosslens Apache-2.0 license. Its upstream license continues to govern that
component.

Gosslens accepts only dependencies that satisfy the repository's dependency
and license policy. New dependencies MUST be reviewed before adoption.
Permitted dependency licenses are limited to MIT, BSD-family, Apache-2.0,
Zlib, and other permissive licenses expressly approved by the project.
GPL, AGPL, LGPL, FFmpeg/libav, GStreamer, binary-only dependencies,
non-commercial or source-available licenses, and unknown or unreviewed
licenses MUST NOT enter the Gosslens dependency graph.

Where a third-party component requires preservation of a copyright notice,
license text, attribution, or other notice, that material MUST accompany the
component or the distributed Gosslens artifact as required by that
component's license.

This file is a human-readable notice. It MUST describe the dependencies that
actually exist in the repository and MUST NOT list planned libraries as
though they have already been adopted.

When a third-party dependency is added, removed, or replaced, this notice
MUST be reviewed and updated in the same change.

### Portable media codecs

Pinned under `third_party/` and fetched by `zig build vendor-sync`. Every one is
permissively licensed and on the vendor allowlist; none is a runtime dependency of
a target that has a platform encoder it prefers.

- **libopus** (`third_party/opus`, v1.5.2, BSD-3-Clause, Xiph.Org Foundation and
  contributors): the one audio codec the engine can own on every target, and the
  codec WebM requires.
- **libwebm** (`third_party/libwebm`, 1.0.0.31, BSD-3-Clause, Google Inc.): WebM
  mux and demux, so the web has a container the engine owns.
- **libvpx** (`third_party/libvpx`, v1.15.0, BSD-3-Clause, The WebM Project
  authors): VP8 and VP9, the web's compatibility floor. Opt-in: only a target
  that needs it pays for the build.
- **dav1d** (`third_party/dav1d`, 1.5.1, BSD-2-Clause, VideoLAN and dav1d authors)
  gives AV1 decode. Opt-in.
- **libaom** (`third_party/aom`, 3.12.0, BSD-2-Clause, Alliance for Open Media):
  AV1 encode, and decode where dav1d does not win the measured budget. Opt-in.
- **openh264** (`third_party/openh264`, v2.6.0, BSD-2-Clause, Cisco Systems): the
  H.264 software fallback where no hardware encoder exists. Opt-in.

**Patent posture, stated rather than assumed.** H.264 and AV1 both sit under
patent pools whose terms are not granted by the software licenses above. Cisco
offers a royalty-free path for openh264 only when its own prebuilt binary is
downloaded at run time, which this project does not do: it builds from source, so
that offer does not apply and any AVC licensing obligation rests with whoever
ships a binary built here. openh264 is therefore a fallback of last resort,
selected only where a target has no hardware H.264 encoder. AV1 is covered by the
Alliance for Open Media patent license in each project's `PATENTS` file, which
travels with the source. VP8 and VP9 carry Google's `PATENTS.TXT` grant on the same
terms. None of these files is modified here.

## Models

Every model is fetched by pinned url and digest from `third_party/models.lock`
and none is committed. The ONNX rail is proven against real published nets:

- **MobileNetV2** (Apache-2.0, the ONNX model zoo) gives the image classifier,
  float and int8.
- **SSD-MobileNetV1** (MIT, the ONNX model zoo) gives the detector, whose graph
  carries the loops, TopK and non-max suppression a real head needs.
- **FCN-ResNet50** (MIT, the ONNX model zoo) gives semantic segmentation.
- **ArcFace ResNet100** (Apache-2.0, the ONNX model zoo) gives the face
  embedding.
- **Depth Anything V2 Small** (Apache-2.0, LiheYoung and contributors) gives
  monocular depth, and is the transformer shape the operator set was widened
  for.

