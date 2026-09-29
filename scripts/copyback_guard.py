#!/usr/bin/env python3
"""No struct the tree writes through its address is copied across a call.

Mojo 1.1.0 passes a `mut` argument of 256 bytes or less BY VALUE, and the
caller stores the callee's copy back over the original when the call
returns (M1 in docs/notes/mut-arguments-and-raw-addresses.md). A write made
to the same struct through its address while the call runs -- by code the
call re-enters, by another thread, by a signal handler -- is erased by that
store. A read-only argument of that size is a copy too, taken before any
such write. B20 (#463) lost two writes to the asyncio executor's
`ExecutorState` exactly so: `_flush_inverted` took it as `mut` and erased
the drain its own pass had begun, an inverted m0serve that never exited on
SIGTERM (SPEC L8); `dispatch_job` did, and erased the completion an eager
task's first step had parked, a request never answered (SPEC L30). The
executor resolves the state by address in every frame now, and nothing but
a convention keeps it that way.

This is the check that does. It reads m0serve's unoptimized IR, compiled
the way `build-serve` compiles it, and fails when any function takes a
listed type by value, returned or not, or takes an argument by value that
holds one inline. Each type's layout comes from its own constructor in the
same IR, so the match does not depend on how KGEN names or orders a
function's parameters. It appends a raising function's error slot and
drops a zero-sized argument, and the census that
`scripts/probes/mut_copyback_matrix.py --census` prints read B20's
`_flush_inverted` as taking a `?` until it learned the first; it still
reads the second that way.

It shows it can fail on every run. A control program takes each listed
type in B20's two shapes -- a `mut` argument of a raising method, and one
of a free function -- and inside a struct that is itself taken `mut`, and
all three copies must be seen, or the guard stops with 2: the census is
blind on this toolchain, or the type has grown past 256 bytes, where M1
cannot reach it and M3 (`noalias`) applies instead, and the listing wants
rethinking rather than a green tick. `--selftest` judges canned IR for
each outcome without a compiler, and every run does that first.

A type belongs in `SHARED` when something writes it by address while a
call may hold it. The sweep in the note ("Who writes them") found no type
but `ExecutorState` with such a writer.

    python3 scripts/copyback_guard.py              # emit both IRs, then judge
    python3 scripts/copyback_guard.py --ir X.ll    # judge an IR already emitted
    python3 scripts/copyback_guard.py --keep       # keep the IR and the control

Needs the packages' `.mojoc` files (`poe build-all`). Exit 0 when no listed
type is passed by value, 1 when one is, 2 when it cannot judge.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "probes"))

from mut_copyback_matrix import _bracketed, _split_top  # noqa: E402


def _sibling(name: str) -> str:
    near = Path(sys.executable).with_name(name)
    return str(near) if near.exists() else (shutil.which(name) or name)


MOJO = _sibling("mojo")

# build-serve's include path and entry file: the IR judged is the binary's.
INCLUDES = ["packages/m0-core/", "packages/m0-http/", "packages/m0-postgres/",
            "packages/m0-wsgi/", "packages/m0-wsgi/mount"]
ENTRY = "packages/m0-wsgi/m0serve.mojo"
MOJOC = ["packages/m0-core/m0_core.mojoc", "packages/m0-http/m0_http.mojoc",
         "packages/m0-postgres/m0_postgres.mojoc", "packages/m0-wsgi/m0_wsgi.mojoc"]

M1_LIMIT = 256
"""Bytes: at or under this a `mut` argument is copied in and stored back."""


@dataclass(frozen=True)
class Shared:
    """A type that must never be passed by value, and why."""

    name: str
    module: str
    make: str
    """An expression that constructs one, for the control program."""
    why: str


SHARED = (
    Shared(
        name="ExecutorState",
        module="m0_wsgi.asgi_executor",
        make="ExecutorState(-1, 1)",
        why="the asyncio executor's port re-enters itself and writes it by "
        "address (B20: SPEC L8, L30)",
    ),
)

CONTROL = '''from {module} import {name}


struct Port_{name}(Movable):
    var addr: Int

    def __init__(out self, addr: Int):
        self.addr = addr

    @no_inline
    def flush_like(mut self, mut st: {name}) raises:
        """B20's `_flush_inverted(mut self, mut st)`."""
        self.addr += 1
        st = {make}


@no_inline
def dispatch_like_{name}(mut st: {name}, slot: Int) raises -> Bool:
    """B20's `dispatch_job(..., mut st, ...)`."""
    st = {make}
    return slot < 0


struct Holder_{name}(Movable):
    var n: Int
    var st: {name}

    def __init__(out self):
        self.n = 0
        self.st = {make}


@no_inline
def holder_like_{name}(mut h: Holder_{name}) raises:
    """The same state held INLINE by a struct that is itself copied."""
    h.n += 1
    h.st = {make}


def control_{name}() raises:
    var st = {make}
    var port = Port_{name}(0)
    port.flush_like(st)
    _ = dispatch_like_{name}(st, 1)
    var h = Holder_{name}()
    holder_like_{name}(h)
'''


def control_source() -> str:
    """One control per listed type, and a `main` that reaches every one."""
    parts = [CONTROL.format(module=t.module, name=t.name, make=t.make) for t in SHARED]
    parts.append("def main() raises:\n" + "".join(
        f"    control_{t.name}()\n" for t in SHARED))
    return "\n\n".join(parts)


def control_shapes(name: str) -> dict[str, bool]:
    """Each control function, and whether its copy holds the type EMBEDDED."""
    return {"flush_like": False, f"dispatch_like_{name}": False,
            f"holder_like_{name}": True}


class CannotJudge(Exception):
    """Exit 2: nothing was measured, so nothing may pass."""


def target_cpu() -> str:
    """build-serve's baseline CPU, so the IR is the shipped binary's."""
    system, machine = platform.system(), platform.machine()
    if system == "Darwin":
        return "apple-m1" if machine == "arm64" else "x86-64-v2"
    return "generic" if machine == "aarch64" else "x86-64-v2"


def emit(entry: Path, out: Path, includes: list[str]) -> float:
    """`mojo build --emit llvm`, KGEN's output before LLVM's own passes."""
    cmd = [MOJO, "build", "--target-cpu", target_cpu(), "--emit", "llvm"]
    for inc in includes:
        cmd += ["-I", inc]
    cmd += [str(entry), "-o", str(out)]
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="13.0")
    start = time.monotonic()
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env)
    if proc.returncode != 0 or not out.exists():
        raise CannotJudge(
            f"`{' '.join(cmd[1:])}` failed (exit {proc.returncode}):\n"
            + (proc.stderr or proc.stdout)[-3000:]
        )
    return time.monotonic() - start


# --- reading the IR ----------------------------------------------------------


@dataclass(frozen=True)
class Define:
    symbol: str
    returned: str
    params: tuple[str, ...]


def defines(ir: str) -> list[Define]:
    out = []
    for line in ir.splitlines():
        if not line.startswith("define "):
            continue
        m = re.search(r'@"([^"]+)"\(', line)
        if not m:
            continue
        head = line[len("define "):m.start()].strip()
        params = _split_top(_bracketed(line, m.end() - 1))
        out.append(Define(m.group(1), head, tuple(params)))
    return out


def _aggregate(param: str) -> str | None:
    """The literal struct type of a by-value parameter, or None."""
    if param.startswith("{") and "} noundef" in param:
        return param[: param.index("} noundef") + 1]
    return None


def _mentions(symbol: str, name: str) -> bool:
    return re.search(r"(?<![\w])" + re.escape(name) + r"(?![\w])", symbol) is not None


def layouts(defs: list[Define], name: str) -> set[str]:
    """The literal struct type(s) `name`'s constructors return by value.

    Over 256 bytes a constructor writes through a pointer instead and the
    set is empty. A raising constructor returns `{ i1, <layout> }`."""
    found = set()
    ctor = re.compile(r"::" + re.escape(name) + r"::__init__\(")
    for d in defs:
        if not ctor.search(d.symbol):
            continue
        brace = d.returned.find("{")
        if brace < 0:
            continue
        ret = d.returned[brace:].strip()
        parts = _split_top(ret[1:-1].strip())
        if len(parts) == 2 and parts[0] == "i1" and parts[1].startswith("{"):
            ret = parts[1]
        found.add(ret)
    return found


_SIZES = {"i1": (1, 1), "i8": (1, 1), "i16": (2, 2), "i32": (4, 4), "i64": (8, 8),
          "ptr": (8, 8), "float": (4, 4), "double": (8, 8), "i128": (16, 16)}


def size_align(t: str) -> tuple[int, int]:
    """Bytes and alignment of an LLVM type, for the types KGEN's structs use."""
    t = t.strip()
    if t in _SIZES:
        return _SIZES[t]
    if t.startswith("{"):
        inner = t[1:-1].strip()
        size, align = 0, 1
        for f in (_split_top(inner) if inner else []):
            fs, fa = size_align(f)
            size = (size + fa - 1) // fa * fa + fs
            align = max(align, fa)
        return (size + align - 1) // align * align, align
    m = re.fullmatch(r"\[(\d+) x (.+)\]", t)
    if m:
        es, ea = size_align(m.group(2))
        return int(m.group(1)) * es, ea
    m = re.fullmatch(r"<(\d+) x (.+)>", t)
    if m:
        es, _ = size_align(m.group(2))
        n = int(m.group(1)) * es
        return n, n
    raise ValueError(f"no size for {t!r}")


@dataclass(frozen=True)
class Copy:
    symbol: str
    index: int
    returned: bool
    embedded: bool


def copies(defs: list[Define], name: str, lays: set[str]) -> list[Copy]:
    """Every function that takes `name` by value.

    Two ways: a parameter OF its layout, in a function whose symbol names
    the type (so a coincidentally identical layout of another type is not
    blamed); or a parameter whose layout CONTAINS it, whatever the symbol
    names -- the type held inline by a struct that is itself copied, whose
    name the symbol never mentions."""
    out = []
    for d in defs:
        named = _mentions(d.symbol, name)
        for i, p in enumerate(d.params):
            agg = _aggregate(p)
            if agg is None:
                continue
            returned = agg in d.returned
            if agg in lays:
                if named:
                    out.append(Copy(d.symbol, i, returned, False))
            elif any(lay in agg for lay in lays):
                out.append(Copy(d.symbol, i, returned, True))
    return out


def _short(symbol: str) -> str:
    return symbol.split("(")[0].split("[")[0]


# --- the judgement -----------------------------------------------------------


def judge(program_ir: str, control_ir: str) -> int:
    program, control = defines(program_ir), defines(control_ir)
    if not program:
        raise CannotJudge("the program's IR holds no function definitions")
    offending = 0
    for t in SHARED:
        lays = layouts(program, t.name)
        if not lays:
            raise CannotJudge(
                f"{t.name}: no constructor returns it by value in the program's "
                "IR. Either the type is gone or renamed (update SHARED), or it "
                f"is over {M1_LIMIT} bytes, where a `mut` argument is `ptr "
                "noalias` (M3) rather than a copy (M1): this guard cannot see "
                "that hazard, so decide what guards the type now"
            )
        try:
            size = f"{max(size_align(lay)[0] for lay in lays)} B"
        except ValueError:
            size = "a size this cannot compute"
        # The control compiled the same type through the same .mojoc, so a
        # layout of its own that differs is itself news.
        control_lays = layouts(control, t.name)
        if control_lays and control_lays != lays:
            raise CannotJudge(
                f"{t.name}: the control's layout {sorted(control_lays)} is not "
                f"the program's {sorted(lays)}; they were built from the same "
                "package, so the IR is not being read the way this assumes"
            )
        seen = {(_short(c.symbol).rsplit("::", 1)[-1], c.embedded)
                for c in copies(control, t.name, lays) if c.returned}
        shapes = control_shapes(t.name)
        missing = [s for s, emb in shapes.items() if (s, emb) not in seen]
        if missing:
            raise CannotJudge(
                f"{t.name}: the control's {', '.join(missing)} took it by `mut` "
                "the way B20's code did, and no copy was seen. The guard is "
                "blind on this toolchain, so it cannot pass: rerun "
                "scripts/probes/mut_copyback_matrix.py and re-read the note"
            )
        found = copies(program, t.name, lays)
        print(f"  {t.name}: {size}, by value at or under {M1_LIMIT} B; the "
              f"control's {len(shapes)} copies of it all seen")
        if not found:
            print("    m0serve: no function takes it by value")
            continue
        offending += len(found)
        print(f"    m0serve: {len(found)} function(s) take it BY VALUE -- {t.why}:")
        for c in found:
            how = "copied in and stored back (M1)" if c.returned else "a read-only copy"
            inside = ", held inline by the argument" if c.embedded else ""
            print(f"      {_short(c.symbol)}  (argument {c.index}{inside}: {how})")
    if offending:
        print(
            "FAIL: a struct written through its address is passed by value, so a\n"
            "write made through the address during the call is lost. Resolve it by\n"
            "address in the frame that uses it (`ref st = Pointer[T,\n"
            "MutUntrackedOrigin](unsafe_from_address=addr)[]`) and pass the address;\n"
            "docs/notes/mut-arguments-and-raw-addresses.md is the rule."
        )
        return 1
    print("OK: no listed type is copied across a call")
    return 0


def selftest() -> int:
    """The judgement on canned IR, no compiler: each exit it can give."""
    import contextlib
    import io

    lay = "{ { ptr, i64, i64 }, i64, i1, i64 }"
    ctor = (f'define internal {lay} @"m0_wsgi::asgi_executor::ExecutorState::'
            '__init__(::SIMD[DType.int, 1],::SIMD[DType.int, 1])"(i64 noundef %0, '
            'i64 noundef %1) #0 {')

    def copy(sym: str, arg: str) -> str:
        return (f'define internal {{ i1, {arg} }} @"{sym}"({arg} noundef %0, '
                'ptr noundef %1) #0 {')

    held = "{ i64, " + lay + " }"
    control = "\n".join([
        ctor,
        copy("copyback_control::Port_ExecutorState::flush_like("
             "copyback_control::Port_ExecutorState,m0_wsgi::asgi_executor::"
             "ExecutorState)_REMOVED_ARG", lay),
        copy("copyback_control::dispatch_like_ExecutorState(m0_wsgi::"
             "asgi_executor::ExecutorState,::SIMD[DType.int, 1])", lay),
        copy("copyback_control::holder_like_ExecutorState(copyback_control::"
             "Holder_ExecutorState)", held),
    ])
    by_pointer = ('define internal void @"m0_wsgi::asgi_executor::f(src::'
                  'asgi_executor::ExecutorState)"(ptr noalias noundef nonnull %0) #0 {')
    same_layout_other_type = copy("m0_wsgi::other::g(src::other::Other)", lay)
    cases = [
        ("clean: by pointer, and another type of the same layout",
         "\n".join([ctor, by_pointer, same_layout_other_type]), control, 0),
        ("B20's shape", "\n".join([ctor, copy(
            "m0_wsgi::asgi_executor::ExecutorPort::_flush_inverted[B](src::"
            "asgi_executor::ExecutorPort,src::asgi_executor::ExecutorState)", lay)]),
         control, 1),
        ("held inline by another argument", "\n".join([ctor, copy(
            "m0_wsgi::asgi_executor::h(src::asgi_executor::Held)", held)]), control, 1),
        ("a read-only copy", ctor + "\n" + (
            f'define internal i64 @"m0_wsgi::asgi_executor::r(src::asgi_executor::'
            f'ExecutorState)"({lay} noundef %0) #0 {{'), control, 1),
        ("no constructor: renamed, or over 256 B", by_pointer, control, 2),
        ("a blind control", ctor, ctor, 2),
        ("an empty program", "", control, 2),
    ]
    failed = 0
    for label, program, ctl, want in cases:
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                got = judge(program, ctl)
            except CannotJudge:
                got = 2
        ok = got == want
        failed += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {label}: exit {got}, want {want}")
    print("selftest " + ("FAILED" if failed else "passed"))
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ir", help="judge this m0serve IR instead of emitting one")
    ap.add_argument("--keep", action="store_true", help="keep the emitted IR and the control")
    ap.add_argument("--selftest", action="store_true",
                    help="judge canned IR for each outcome, no compiler")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    td = Path(tempfile.mkdtemp(prefix="copyback-guard-"))
    try:
        # The judgement on canned IR first: milliseconds, and a guard whose
        # own reading has regressed must not get as far as a verdict.
        import contextlib
        import io

        with contextlib.redirect_stdout(io.StringIO()) as quiet:
            broken = selftest()
        if broken:
            raise CannotJudge("the guard's own selftest fails:\n" + quiet.getvalue())
        missing = [p for p in MOJOC if not (ROOT / p).exists()]
        if missing:
            raise CannotJudge(f"no {', '.join(missing)}: run `poe build-all` first")
        version = subprocess.run([MOJO, "--version"], capture_output=True,
                                 text=True).stdout.strip()
        print(f"copy-back guard ({version}):")
        control_src = td / "copyback_control.mojo"
        control_src.write_text(control_source())
        control_ll = td / "control.ll"
        spent = emit(control_src, control_ll, INCLUDES)
        if args.ir:
            program_ll = Path(args.ir)
        else:
            program_ll = td / "m0serve.ll"
            spent += emit(ROOT / ENTRY, program_ll, INCLUDES)
        start = time.monotonic()
        rc = judge(program_ll.read_text(), control_ll.read_text())
        print(f"  ({spent:.0f} s compiling, {time.monotonic() - start:.1f} s reading)")
        return rc
    except CannotJudge as e:
        print(f"CANNOT JUDGE: {e}")
        return 2
    except Exception:
        # A crash must not exit 1, which says a listed type IS copied.
        import traceback

        traceback.print_exc()
        print("CANNOT JUDGE: the guard itself failed")
        return 2
    finally:
        if args.keep:
            print(f"  kept: {td}")
        else:
            shutil.rmtree(td, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
