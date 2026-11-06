# libm0core in the m0serve wheel

`libm0core` is the C-ABI shared library built from m0-core. It is
m0serve's private runtime: it ships inside the m0serve wheel and nowhere
else, and no ABI is promised to anyone outside this repository
(DECISIONS D56). Releases v0.1.0 through v1.8.0 attached it as an asset,
and those assets keep their notices; later releases attach none. How the
artifact came to load off the machine that built it, from 2026-08-23 on,
is [a dated note](notes/the-c-abi-artifact.md).

## What ships

- `poe build-ffi` builds `packages/m0-core/ffi_exports.mojo` into
  `libm0core.so` (`.dylib` on macOS) for the oldest CPU each platform
  must support: `--target-cpu apple-m1` on macOS arm64, `x86-64-v2` on
  Linux and macOS x86-64, and `generic` on Linux aarch64. On macOS it
  builds with `MACOSX_DEPLOYMENT_TARGET=13.0`, the floor the Mojo
  toolchain's own wheel is tagged for.
- `scripts/relocate.py` then rewrites the install name and the search
  path `mojo build` records from the build machine, so the library finds
  its runtime beside itself: `@loader_path` on macOS, `$ORIGIN` on Linux.
- `poe stage-wheel` copies it into the wheel's `_lib/`, beside the
  binary's `_bin/`, with the Mojo runtime libraries it depends on.
  `scripts/bundle_artifact.py` finds those by walking the dependency
  graph, so a toolchain that adds a library is followed.
- The library exports one function, `m0_shared_fetch_add`. `m0pub` calls
  it through `ctypes` to number the events it publishes, and finds the
  library through `M0_CORE_LIB`, which the wheel's launcher and
  `m0serve --realtime` set to the copy beside the binary. Without it,
  `m0pub` publishes unnumbered frames.
- `scripts/ffi_portability_check.py --require-self-contained` refuses a
  `_lib/libm0core` whose search paths are not relative to itself, or that
  depends on a library neither shipped beside it nor supplied by the
  platform. It runs in `stage-wheel`, which `smoke-wheel` runs on every
  pull request, and again in the release's `wheel-inspect` job.
  `poe smoke-ffi` calls the export through `ctypes` on every pull
  request.

Publishing resumes, with a versioned ABI, when a named caller outside
this repository asks for a C ABI.

## The licensing position

The wheel redistributes the Mojo runtime libraries it bundles, and no one
source settles their licence:

- Mojo's compiler and runtime sources were open-sourced on 2026-08-18
  under Apache 2.0 with LLVM Exceptions, by `modular/modular`'s root
  `LICENSE`. The runtime's sources are in that repository (`KGEN/`,
  `AsyncRT/`, `Support/lib/`).
- The `mojo_compiler` wheel that ships the prebuilt libraries declares
  `License: LicenseRef-MAX-Platform-Software-License` in its METADATA, in
  1.0.0, 1.1.0 and 1.2.0 alike, and carries no licence file.
- That string now names the MAX License of 2026-10-21, which governs the
  1.2.0 runtime. Its section 1.2 lets an application with material
  functionality of its own redistribute MAX in object code form, under
  terms of its choosing, provided a human-readable copy of the Terms goes
  with it. Its section 1.5 keeps the portions released under Apache 2.0
  with LLVM Exceptions, as the licence file or header accompanying each
  identifies them, under those terms. The runtime's sources carry those
  headers, and the built files carry neither.

The LLVM Exception covers what is compiled into `libm0core` itself. The
runtime libraries beside it are redistributed as files of their own,
which NOTICE's Apache §4 compliance covers in the reading where they are
Apache-licensed. So from m0serve 1.16.0 the wheel ships both texts:
`LICENSE.max.txt`, the terms of 2026-10-21 verbatim, beside
`LICENSE.mojo-runtime.txt`, with a `NOTICE.txt` that says why. The
wheel's licence expression stays `MIT AND Apache-2.0 WITH
LLVM-exception`: a `LicenseRef-` for MAX would flag every install of
m0serve for review on a reading nothing confirms, and the notice says
what the expression cannot. An `m0 build --release` artifact and an
`m0 image` carry the same runtime, and from m0 0.14.0 the same texts
(SPEC N56).

Modular shipping a licence file in the `mojo-compiler` wheel that
identifies the runtime's components would settle the question under
section 1.5. Each new release's METADATA is worth the same one-line
check.
