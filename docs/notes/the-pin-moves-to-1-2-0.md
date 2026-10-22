# The pin moves to Mojo 1.2.0 — 2026-10-22

Mojo 1.2.0 and MAX 26.7.0 reached PyPI on 2026-10-22, with a new MAX
License dated the day before. This is the record of moving the pin onto
them: `mojo==1.2.0`, and `max-core==26.7.0` in the `max` group, which pins
`mojo-compiler==1.2.0` and so moves with it.

## What was measured, and against what

Each claim below was measured on 1.2.0 and, where the claim is a change, on
1.1.0 as the null case: the same file, run by `uv run --no-project
--with mojo==1.1.0` from uv's cache, since the venv now holds 1.2.0.

**`Float64` parsing rounds correctly; printing still does not.** The shortest
forms CPython's `repr()` gives for 120,000 doubles, read by `Float64()` and
compared bit for bit with the double each names:

| decimals | 1.1.0 | 1.2.0 |
|---|---|---|
| 60,000 random bit patterns | 41 misses | 0 |
| 60,000 between 1e15 and 1e23 | 3,401 misses | 0 |

The 1.1.0 random row is in line with the Known issue's record (47 and 55
of 60,000),
and `parse_json_number` now reads `2.3914322253667574e+17` exactly, where
1.1.0 read one below. `scripts/probes/float64_rounding_probe.mojo` still
exits 1: its six parsing cases pass and its five printing cases still miss,
so the Known issue is rewritten to the printer alone, which is what the
upstream changelog's `atof()` entries predict.

**`RawFileDescriptor` is laxer than the changelog says.** The release notes
say a negative descriptor aborts, that `-1` is the type's niche, so
`Optional[RawFileDescriptor]` is no bigger than the type, and that the value
is no longer a public field. On 1.2.0 as shipped, none holds:
`RawFileDescriptor(Int32(n))` with `n = -1` at run time constructs, under
`-D ASSERT=all` too; `Optional[RawFileDescriptor]` is 8 bytes against the
type's 4; `.value` reads. What is real is the rename, an `Int32`
constructor with no conversion from `Int`, and a `c_int` `.value`. The
fork's `-1` for a closed descriptor (three sites, and the tests') therefore
still works, and it is the next pin's question: if the notes describe
`main`, a later release aborts on it.

**The stdlib's `read` and `write` changed signature.** Read from `mojo build
--emit llvm` of a program calling `read_bytes` and `write_bytes`:

| | 1.1.0 | 1.2.0 |
|---|---|---|
| `read` | `declare i64 @read(i64, ptr, i64)` | `declare i64 @read(i32, ptr, i64)` |
| `write` | `declare i64 @write(i64, ptr, i64)` | `declare i64 @write(i32, ptr, i64)` |

**Unchanged, re-measured:**

- `mut_copyback_matrix.py`'s verdicts, all three mechanisms: a `mut`
  argument of 256 B or less is still passed by value and stored back, so
  CLAUDE.md's rule and SPEC L31's gate stand
  ([mut-arguments-and-raw-addresses](mut-arguments-and-raw-addresses.md)).
- What `mojo run` prints for each phase, which `scripts/sabotage_lib.py`
  parses: the diagnostic line, `failed to parse the provided Mojo source
  module`, `execution exited with a non-zero result: N`, `execution
  crashed`, `ABORT:`, and a suite's `PASS`, `FAIL` and `SKIP` lines. A
  failed `where` constraint now ends in `failed to parse` rather than
  `failed to run the pass manager`; both are the compile phase to the
  library. `sabotage-trailers` and `sabotage-header-bytes` catch every arm.
- `mojo build` still links only through the literal name `cc`: a `clang` on
  `PATH` and `CC=clang` are refused with `unable to find suitable c
  compiler for linking`, so `m0`'s `c-compiler` check stays as written.
- An imported module holding a malformed `def` nothing calls still builds
  with exit 0, so `smoke-scaffold-dev` keeps breaking the entry file.
- The runtime a binary loads: `libm0core` links `libKGENCompilerRTShared`
  alone, and 1.2.0's `mojo_compiler` wheel ships the same three runtime
  libraries as 1.1.0's, `libKGENCompilerRTShared` loading the same set
  (macOS; the Linux closure is CI's `smoke-wheel`).
- The wheels' licence metadata, `LicenseRef-MAX-Platform-Software-License`,
  with no licence file; what the new licence changes for the bundled
  runtime is [FFI_DISTRIBUTION](../FFI_DISTRIBUTION.md).

## What broke, and what it cost

| class | sites | note |
|---|---|---|
| `FileDescriptor` -> `RawFileDescriptor` | 334 lines, 43 files | gone from the prelude and from `std.io`, with no alias |
| its constructor takes an `Int32` | 260 | `RawFileDescriptor(c_int(fd))`; four sites that wrapped a `c_int` in `Int()` pass it straight |
| `.value` is a `c_int` | 28 | `Int(fd.value)` where an `Int` is wanted, as at every `close_fd` and backend call |
| the tree's `read` and `write` declarations | 6 | a `c_int` descriptor, to match the stdlib's: a second declaration of a symbol with another signature fails at LLVM lowering |
| `std.hashlib` -> `std.hash` | 1 | `response_cookie_jar.mojo` |
| `std.io.write` -> `std.format` | 1 | `Writable` and `Writer`, in `asgi_executor.mojo` |
| a `^` on a borrowed argument | 7 | a new warning, and the ratchet's floor is 0 |
| the `StringSpan` recursion | 3 | below |

The order the gates found them is the argument, again, for running the
whole sequence: `build-all` stopped at the first package, `check-fork-package`
found the `.value` sites `precompile src` never elaborates, the test suites
found the rest, and only LLVM lowering of the one test program found the
`read` declaration.

## A recursive declaration, depending on what came first

1.2.0 can refuse to compile a `StringSpan` built from bytes:

```mojo
def text(b: List[UInt8]) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(b)))


def main():
    print(text([104, 105]))
```

```text
error: attempt to resolve a recursive reference to declaration 'CStringSpan.__init__'
note: by declaration 'StringSpan.as_c_string_span'
note: by declaration '_fdopen.__init__'
note: by declaration '_flush'
note: by declaration 'print'
```

Move `main` above `text` and it compiles and prints `hi`. The same body
compiles inside `main`, in a struct's method, and after a `String()` in
the same function, and fails in a free function above `main` whether the
bytes arrive as a borrowed, an owned or a `Span` argument. So whether a
program trips it depends on what the compiler elaborated first, not on the
expression. 1.1.0 compiles every one of these shapes.

Three test files tripped it, each in a helper above its tests, and each in
`mojo_suite`'s per-file `mojo doc` check rather than in the one-program
build. Each now builds the `String` with `String(unsafe_from_utf8=...)`,
which copies the same bytes without the intermediate span and compiled in
every position tried; CLAUDE.md's pattern 11 makes that the spelling.
61 other sites build a `StringSpan` the same way and compile today, in
every program the gates build, because something else is elaborated first:
41 copy it into a `String` at once and could take the same spelling, and
20 keep the span as a view (the fork's header and body accessors, the
bridge's decode path), where a copy would cost. Half of the 61 are in
tests and the scaffold's templates. They are left alone in this move: a
change of order that trips one fails its own gate, and rewriting 41 lines
that compile is a change of its own. Not yet reported upstream; the
program above is the report.

## Still unknown

- Whether 1.2.0 fixes the free-threaded `PyObject` header
  (modular/modular#5726). It needs a 3.14t interpreter, so the weekly
  `py-canary` run answers it, as at 1.1.0.
- The Linux leg was not run locally: CI's Linux jobs are its gate. The
  epoll backend's `.value` sites compile on macOS through
  `check-fork-package`, but a body under a Linux-only `comptime if` does not.
- Performance: no bench was re-run. The compiler's changelog promises
  faster compiles and a faster `atof`, neither of which a request reaches.
