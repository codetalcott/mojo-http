# The Linux floor is the runtime's, not the build host's — 2026-10-06

A measurement from the engineering record. It corrects the known issue
"The Linux wheel misses RHEL 9 by one glibc minor", whose stated closer —
build inside a `manylinux_2_34` container — would not have closed it.

## The question

The Linux wheel is tagged `manylinux_2_35`. Ubuntu 22.04 and Debian 12
install it; RHEL 9 and its rebuilds, at glibc 2.34, are declined by `pip`.
The issue, and README's platform table with it, said the floor was the
build host's (`ubuntu-22.04`, glibc 2.35) and that building inside a
`manylinux_2_34` container would reach 2.34. The round that set out to do
that measured first.

## What was measured

The two Linux wheels of release 1.11.0, downloaded from the release and
read with `objdump -T` inside a `quay.io/pypa/manylinux_2_34_aarch64`
container (AlmaLinux 9.8, glibc 2.34, libstdc++ from GCC 11):

| file | needs | symbol |
|---|---|---|
| `_bin/m0serve` | GLIBC_2.34 | the toolchain's floor, nothing above it |
| `_lib/libAsyncRTRuntimeGlobals.so` | GLIBC_2.35 | `__rseq_size` |
| `_lib/libKGENCompilerRTShared.so` | GLIBCXX_3.4.30 | `std::condition_variable::wait` |
| `_lib/libMSupportGlobals.so` | GLIBC_2.34, GLIBCXX_3.4.14 | |
| `_lib/libm0core.so` | none versioned | |

Both architectures read the same. The two runtime libraries are copied
unchanged from the toolchain's `modular/lib` by `bundle_artifact.py`, and
the toolchain's own copies carry the same requirements, so the wheel
inherits them from Modular's build of the runtime, not from the runner.
The m0serve binary itself, built on a 2.35 host, requires only 2.34.

Two consequences:

- **A `manylinux_2_34` build would not lower the tag.** `wheel_tag.py`
  takes the strictest floor across the staged files, and
  `libAsyncRTRuntimeGlobals.so` would still say 2.35. The build log has
  said so at every release, in the tag script's note that the floors
  differ and which file set the strictest; nobody read it against the
  issue.
- **Even relabelled, the wheel would not run on RHEL 9.** The runtime
  needs `GLIBCXX_3.4.30`, which is GCC 12's libstdc++; RHEL 9 ships GCC
  11's (3.4.29) as its system library, and its gcc-toolsets add a newer
  compiler without replacing it. `pip` refusing the wheel on the glibc
  tag is, for RHEL 9, the right answer reached by accident.

The compiler meets the same wall: in that container `uv sync` installed
the pinned toolchain, and `mojo --version` failed with
`GLIBCXX_3.4.30' not found`. The toolchain's `manylinux_2_34` tag is a
glibc promise, not a libstdc++ one.

## What was decided

Nothing to build. The issue stays open with its cause corrected and a
closer that can be read off a future release's wheel: when
`libAsyncRTRuntimeGlobals.so` needs no symbol above `GLIBC_2.34` and
`libKGENCompilerRTShared.so` none above `GLIBCXX_3.4.29`, the measured
tag drops to `manylinux_2_34` on its own and RHEL 9 is reached, and both
facts are one `objdump -T` per file on the wheel's `_lib/`. The tag
script now names the file that set the floor on every run rather than
only when floors differ, so the next person asking the question reads
the answer where the wheel is built. Bundling a libstdc++ was
considered and not done: it would meet the GLIBCXX half and not the
glibc half, and a wheel that ships the C++ runtime is a different
promise than the one the consume jobs prove.
