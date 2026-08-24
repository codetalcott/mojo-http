# The C-ABI artifact does not load off the machine that built it

`libm0core` is published with every GitHub release for "Bun's `dlopen`,
Node's N-API, or Python's `ctypes`". **It does not work for any of them.**
Every release from v0.1.0 to v0.7.0 ships an asset that a consumer cannot
load.

## What is wrong

A Mojo shared library records a search path (`LC_RPATH` on Mach-O,
`DT_RUNPATH` on ELF) pointing at the **absolute path of the venv it was
built in**, and resolves the Mojo runtime through it. Downloading v0.7.0 and
inspecting it:

```
install name  : packages/m0-core/libm0core.dylib
search paths  : ['/Users/runner/work/mojo-http/mojo-http/.venv/lib/python3.13/site-packages/modular/lib']
dependencies  : ['@rpath/libKGENCompilerRTShared.dylib', '/usr/lib/libSystem.B.dylib']
```

That search path is the **CI runner's home directory**, baked into a
published asset. `dlopen` on any other machine fails with:

```
Library not loaded: @rpath/libKGENCompilerRTShared.dylib
  tried: '/Users/runner/work/mojo-http/mojo-http/.venv/.../modular/lib/...' (no such file)
```

Three distinct defects, two of which are entirely ours:

1. **The search path is a build-tree absolute path.** Ours. Nothing resolves
   through it anywhere else.
2. **The install name is a build-tree relative path**
   (`packages/m0-core/libm0core.dylib`). Ours. `dlopen` ignores it, but
   anything that *links* against the library records it and then cannot find
   it.
3. **The Mojo runtime is not shipped alongside.** Not ours to fix
   unilaterally — see the licensing question below.

## Why no test caught it, for seven releases

`smoke-ffi` builds the library and `dlopen`s it **in the build tree**, where
the venv it was linked against is still present. It therefore passes on
exactly the machine where the defect cannot manifest, and would pass forever.
The release workflow runs the same smoke, so CI proving the artifact "through
the same `ctypes` smoke" proved only that it works *there*.

This is a test-design flaw, not an oversight: a load attempt on the build
machine cannot detect a dependency on the build machine.

`poe check-ffi-portable` (`scripts/ffi_portability_check.py`) checks the
property a load attempt cannot: **every recorded search path is relative to
the artifact, and every dependency is either a system library or shipped
beside it.** Static inspection, both formats. It fails on the current
artifact and on every published one, which is how it was verified.

## The fix, demonstrated

Rewriting the two paths that are ours and shipping the runtime's dependency
closure alongside produces an artifact that loads from an unrelated directory
with a clean environment:

```
install name  : @rpath/libm0core.dylib
search paths  : ['@loader_path']
=> portable: every search path is self-relative and every dependency is a
   system library or shipped alongside
```

The runtime closure is **three files, 1.57 MB** — `libKGENCompilerRTShared`
(1.12 MB), which itself needs `libMSupportGlobals` (0.12 MB) and
`libAsyncRTRuntimeGlobals` (0.33 MB). It is a closure, not one file; the
first attempt shipped only the first and failed on the second.

Verified: the bundled artifact `dlopen`s from `/tmp` with `DYLD_LIBRARY_PATH`
unset and answers the public FNV-1a and xxHash32 vectors.

## The open question: may we redistribute the Mojo runtime?

**Not resolved here, because it is a licensing determination and the two
sources of truth disagree.**

- **Mojo's compiler and tooling were open sourced on 2026-08-18**, under
  **Apache 2.0 with LLVM Exceptions**. Verified from `modular/modular`'s own
  root `LICENSE`, not only the announcement; no carve-out for the runtime
  appears in it.
- **The runtime sources are in that repo** — `KGEN/`, `AsyncRT/`,
  `Support/lib/`, with real build files and C++ — so the three libraries are
  built from what is now Apache-licensed source.
- **But the wheel that ships the prebuilt binaries says otherwise.** The
  three dylibs are installed by `mojo_compiler-1.0.0`, whose METADATA
  declares `License: LicenseRef-MAX-Platform-Software-License` — Modular's
  proprietary MAX Platform license, not Apache.

So the *sources* are Apache 2.0 + LLVM Exceptions while the *binaries as
distributed to us* declare a proprietary license. The likeliest explanation
is stale wheel metadata — Mojo 1.0.0 shipped the same day as the
relicensing — but "likeliest" is not a basis for redistributing someone
else's binaries.

Note also that the LLVM Exception addresses a different case than this one.
It covers portions of the Software *embedded into Object form as a result of
compiling your source* — which is `libm0core.dylib` itself, and is fine. It
does not obviously cover redistributing the runtime libraries as separate
files, which is ordinary Apache §4 redistribution and depends on those files
actually being Apache-licensed.

**What would settle it**, in increasing order of effort: the wheel metadata
being corrected in a later Mojo release; a statement from Modular about
redistributing prebuilt runtime binaries; or building the runtime from the
Apache-licensed source ourselves rather than shipping Modular's build.

## Recommended sequence

1. **Fix defects 1 and 2 now.** They are ours, need no permission, and are
   strictly an improvement: the artifact stops looking in a directory that
   exists on nobody's machine and starts looking beside itself — which a
   consumer can satisfy by dropping in three files from their own Mojo
   install. Requires post-link `install_name_tool` (macOS) / `patchelf`
   (Linux), because the offending rpath is added by `mojo build` and cannot
   be suppressed with a linker flag.
2. **Document the three files** a consumer must supply, until (3).
3. **Ship the runtime alongside once the licensing question is answered.**
   The mechanism is proven and `check-ffi-portable` already validates the
   result; it becomes a release-workflow step and a CI gate at that point.

Until (1) lands, `check-ffi-portable` is a diagnostic rather than a gate —
gating on a known-failing property would only block releases.
