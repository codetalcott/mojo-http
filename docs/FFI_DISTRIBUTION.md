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

## Update, 2026-08-24: the two owned defects are fixed

`build-ffi` now rewrites both paths after the link (they cannot be
suppressed with a linker flag, because `mojo build` adds them itself):

| | before | after |
|---|---|---|
| install name | `packages/m0-core/libm0core.dylib` | `@rpath/libm0core.dylib` |
| search path | `/Users/runner/work/.../modular/lib` | `@loader_path` |
| state | **BROKEN** | **SATISFIABLE** |

macOS uses `install_name_tool` plus an ad-hoc `codesign` — arm64 invalidates
the signature on any Mach-O edit, and an unsigned dylib will not load at all.

**`smoke-ffi` was silently undoing this.** It ran its own `mojo build` into
the same output path, so it overwrote whatever `build-ffi` produced and
tested an unfixed artifact. It now takes `build-ffi` as a dependency and
tests what that task actually emits, supplying the Mojo runtime through
`DYLD_LIBRARY_PATH` — which is the documented consumer requirement, so the
smoke exercises it rather than accidentally depending on a baked-in path.

### Linux was never broken in the way macOS is

Parsing the published `.so` (the checker reads ELF itself, so a macOS
checkout can inspect it) shows **no `DT_NEEDED` entries at all** and no `.so`
references anywhere in the file: the Linux artifact is statically linked and
resolves nothing at load time. Its `DT_RUNPATH` was inert debris — it named
`/home/runner/work/...` but nothing was ever looked up through it.

So **the missing-runtime problem is macOS-only**, and the Linux artifact has
been loadable all along. That is worth stating plainly because the original
report implied both were broken.

> **Correction, 2026-08-25.** That holds for `libm0core.so` and does not
> generalise. `bin/m0serve` links the three Mojo runtime `.so` files
> dynamically on Linux, exactly as on macOS — the first Linux CI run that
> tried to bundle the executable is what established it, by refusing. The
> lesson is narrow and worth keeping: "the Linux artifact is statically
> linked" was measured on one file and then carried as a platform fact.
> Nothing in the tooling decides by platform any more, only by what the file
> records.

The checker reports three states rather than pass/fail, which is what makes
it gateable: `BROKEN` (only loads where it was built), `SATISFIABLE` (loads
once named files are placed beside it), `SELF-CONTAINED` (loads with nothing
else). `--require-self-contained` demands the strongest. Today macOS is
satisfiable and Linux is self-contained; neither is broken.

## The licensing question, re-checked 2026-08-24

**The nightly metadata has not changed.** `mojo_compiler-1.1.0.dev2026082305`
— built five days *after* the relicensing — still declares:

    License: LicenseRef-MAX-Platform-Software-License

(read via HTTP range requests against the 71.6 MB wheel's central directory,
so this costs one request rather than a download.)

So the discrepancy is not a same-day packaging slip that has since been
corrected. It has persisted across five nightlies. That does not make
redistribution impermissible — the sources really are Apache-2.0 — but it
does remove the "obviously just stale" reading, and it is not a question to
answer by inference.

### Building the runtime from source: assessed, not recommended

The sources are Apache-2.0 and the repo ships `bazelw` and `MODULE.bazel`, so
it is possible in principle. In practice `KGEN/BUILD.bazel` is an MLIR-based
compiler stack (`CODialect`, `HLCFDialect`, TableGen targets), so this means
building LLVM/MLIR — hours and gigabytes, per platform, in CI, kept in step
with the pinned Mojo version, and re-done on every pin move. For a 1.57 MB
bundle that only affects macOS, that is far more machinery than the problem
justifies.

**Ask Modular instead.** The question is one line — *are the prebuilt runtime
libraries in the `mojo-compiler` wheel covered by the Apache-2.0 relicensing,
or still under the MAX Platform license?* — and the forum and Discord are
both linked from the wheel's own metadata. A definitive answer costs nothing
and unblocks the last step; the mechanism is already proven and
`check-ffi-portable --require-self-contained` already validates the result.

## Resolved, 2026-08-24: the bundle ships

All three defects are fixed. `poe bundle-ffi` assembles
`dist/libm0core-<platform>/` containing the artifact, the Mojo runtime it
loads, and both licences — and **refuses to finish unless the result is
self-contained**, so the assembly step and the assertion cannot drift apart.
Verified by loading it from `/tmp` with `DYLD_LIBRARY_PATH` and
`DYLD_FALLBACK_LIBRARY_PATH` unset: every public vector passes.

**The closure is discovered, not listed.** `bundle_artifact.py` walks the
dependency graph, so a toolchain bump that adds a fourth library is picked up
instead of silently producing a broken bundle — which is exactly the failure
the first hand-written attempt hit, shipping only the library named in the
error message and then failing on its dependency.

CI runs `bundle-ffi` on every commit, and the release workflow ships the
bundle as `<asset>.tar.gz` beside the bare library (kept so existing download
URLs keep working). A release can no longer publish an asset that only loads
on the runner.

### Why proceeding was reasonable, and what it does not rest on

The evidence is not unanimous, so the position is stated rather than implied:

- The `mojo_compiler` wheel contains **only** `modular/bin`, `modular/lib`
  and `mojo` — the compiler and its runtime, **no MAX components**. That is
  precisely the scope open sourced on 2026-08-18.
- It ships **no licence file of its own**, so its `License:` metadata field
  is the only contrary signal — and a packaging field is weak evidence
  against the `LICENSE` actually governing the sources.
- The same runtime code is *already* redistributed by this project, embedded,
  in the statically linked Linux artifact. macOS differs only because
  Modular's toolchain links it dynamically there; a licence outcome should
  not turn on their linking strategy.

**Nothing here rests on the LLVM Exception.** That exception excuses Apache
sections 4(a), 4(b) and 4(d) for portions embedded into Object form by
compiling one's own source — which describes `libm0core` itself and the
Linux artifact, and was never in doubt. Rather than argue it stretches to
separate files, the bundle simply **complies with section 4 in full**: the
Apache text ships as `LICENSE.mojo-runtime.txt`, and `NOTICE.txt` carries
attribution plus an explicit 4(b) modification notice (install name, rpath
and ad-hoc re-signing changed; executable code byte-for-byte as built).

If Modular later states that the prebuilt binaries are *not* Apache-licensed,
the remedy is one line — drop the copy step — and everything else here still
stands.

**That remedy shrinks once anything is on PyPI.** A GitHub release asset can
be deleted. A PyPI file cannot be re-uploaded under the same filename ever
again, even after deletion, and a *yank* (PEP 592) leaves the file
downloadable and installable by exact pin — it only removes it from range
resolution. So "drop the copy step" fixes future versions and recalls
nothing. The actual remedy for a published wheel is: yank, republish without
the component, and record in this file what was shipped and when. Worth
knowing before the first upload rather than after.

## Recommended sequence

1. ~~**Fix defects 1 and 2.**~~ **Done** — see the update above. macOS is
   `SATISFIABLE`, Linux is `SELF-CONTAINED`, neither is `BROKEN`.
2. **Document the three files** a consumer must supply on macOS. Done in the
   README; the release notes should say it too.
3. **Ship the runtime alongside once the licensing question is answered** —
   by asking Modular, not by inferring from the Apache-2.0 sources while the
   shipped binaries say otherwise. The mechanism is proven and
   `check-ffi-portable --require-self-contained` already validates it.

`check-ffi-portable` can now be a **gate** rather than a diagnostic: it
passes today on both platforms, and fails if either regresses to `BROKEN`.
It is not yet wired into CI as one — that belongs with the release workflow
change in (3).

## 2026-08-25: executables differ from dylibs, and both tools missed it

Scoping the PyPI wheel meant pointing this machinery at `bin/m0serve` instead
of `libm0core`. It answered immediately, and the answer was wrong:

```
$ python3 scripts/ffi_portability_check.py bin/m0serve
install name  : @rpath/libKGENCompilerRTShared.dylib
dependencies  : ['/usr/lib/libSystem.B.dylib']

SELF-CONTAINED — nothing is resolved at load time.
exit 0
```

`otool -L` prints a header line, then — **for a dylib only** — the file's own
`LC_ID_DYLIB` install name, then its dependencies. `inspect_macho` dropped the
first entry unconditionally. `bin/m0serve` is an `MH_EXECUTE` and has no
`LC_ID_DYLIB` at all, so what got dropped was
`@rpath/libKGENCompilerRTShared.dylib` — the Mojo runtime — leaving only a
system library, and therefore nothing to complain about.

`bundle_ffi.py` had its own copy of the same four lines, so it would have
copied **zero** runtime libraries and declared the bundle complete. The two
tools would then have agreed with each other about an artifact neither could
see. That is the same shape as the defect that shipped for seven releases,
one level up: not a test that passes where the defect cannot appear, but a
*pair* of tests blind in the same direction.

The dependency was real. Deleting the build-machine rpath from a copy and
running it:

```
$ install_name_tool -delete_rpath /Users/.../.venv/.../modular/lib /tmp/m0serve
$ /tmp/m0serve --version
dyld: Library not loaded: @rpath/libKGENCompilerRTShared.dylib
  Reason: no LC_RPATH's found
```

### The fix

The parse moved to `scripts/binfmt.py`, shared by both tools, keyed on
**`LC_ID_DYLIB`'s presence** rather than on the header's filetype — an
`MH_BUNDLE` may or may not carry one, and the question being asked is only
ever *is the first entry this file's own name?*

`binfmt.py --selftest` runs both cases against canned `otool` output, in CI,
beside the warning-parser self-test and for the same reason: a parser whose
regression is invisible to every test that uses it is not a guard.

### Verified by sabotage

| command | before | after |
|---|---|---|
| `ffi_portability_check.py bin/m0serve` | `SELF-CONTAINED`, exit 0 | **`BROKEN`, exit 1** |
| `ffi_portability_check.py .../libm0core.dylib` | `SATISFIABLE`, exit 0 | **`SATISFIABLE`, exit 0** |
| `bundle_artifact.py bin/m0serve <dir>` | copies 0 dylibs | **copies 3, 1.57 MB** |

The middle row is the one worth insisting on. Without it, "the checker now
fails on `m0serve`" is equally consistent with having simply broken the
checker; with it, the change is localised to the case that was wrong.

Reintroducing the bug in a copy of `binfmt.py` (`entries[1:]` unconditionally)
fails the self-test with `executable's runtime dependency was dropped`, and
assuming every Mach-O has an install name fails it the same way.

### `bin/m0serve` had no post-link surgery at all

`build-ffi` rewrote install name and rpath; `build-serve` did neither, because
the surgery was ~25 lines of shell inside one task rather than a thing tasks
could share. So every `bin/m0serve` ever built recorded a search path into the
venv that built it. It now runs `scripts/relocate.py`, which `build-ffi` also
runs, and takes **two** self-relative rpaths — `@loader_path` and
`@loader_path/../_lib` — so one build output serves both the flat tarball
layout and the wheel's `_bin/`+`_lib/` layout with no second pass.

`build-serve` then completes the bundle in place, so `bin/` *is* the shipped
shape rather than a development-only arrangement that works for a different
reason. That closes the loop the original defect opened: the binary the smokes
exercise is now the binary a user gets. Before this, removing the venv rpath
broke every `serve-*` and `smoke-*` task, which is a fair measure of how much
the development path had been relying on it.

### A third machine dependency, previously invisible: the deployment target

```
$ otool -l bin/m0serve | grep -A4 LC_BUILD_VERSION
 platform 1
    minos 26.0
      sdk 26.5          (build host: macOS 26.6.1)
```

A Mojo binary inherits the build host's SDK. The Mojo toolchain *wheel* is
tagged `macosx_13_0_arm64`, but what it emits here requires macOS 26 — so a
PyPI wheel tagged from `uv.lock` would install cleanly on macOS 15 and then
fail in dyld, and the published `libm0core-macos-arm64.dylib` assets carry
whatever `minos` the runner happened to have.

The checker reports `min OS` now and accepts `--require-min-os=X.Y`. The
consequence for the wheel is that **the platform tag must be measured from the
staged binary, never copied from the toolchain's.**

### It is a choice, though, not a fate

`mojo build` honours `MACOSX_DEPLOYMENT_TARGET`. Measured:

```
$ MACOSX_DEPLOYMENT_TARGET=13.0 mojo build --emit shared-lib ... -o probe.dylib
$ otool -l probe.dylib | grep -A3 LC_BUILD_VERSION
    minos 13.0
```

So `build-ffi` and `build-serve` pin it to **13.0** — the same version the
Mojo toolchain's own wheel is tagged for (`macosx_13_0_arm64`). Not lower:
the toolchain does not claim to run below that, and promising more than the
compiler does would just move the failure. Modular's runtime dylibs turn out
to be built for 11.0, so they satisfy 13.0 comfortably — `wheel_tag.py`
reports the spread rather than hiding it:

```
note: floors differ across files, taking the strictest (macosx_13_0_arm64):
  macosx_11_0_arm64 <- libAsyncRTRuntimeGlobals.dylib
  macosx_13_0_arm64 <- libm0core.dylib
```

Pinning changes the wheel's reach from macOS 26+ to macOS 13+, and — more
usefully — makes the floor a property of this repository rather than of
whichever image GitHub is currently calling `macos-latest`. The measurement
stays regardless: `smoke-wheel` asserts the tag is never below the binary's
own `LC_BUILD_VERSION`, so if the pin ever stops working the wheel gets a
narrower tag instead of a false promise.
