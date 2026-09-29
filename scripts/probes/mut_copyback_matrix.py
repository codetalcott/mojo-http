#!/usr/bin/env python3
"""When a write made through a raw address is lost across a call, on Mojo 1.1.0.

B20 (PR #463) found `_flush_inverted` and `dispatch_job` taking the asyncio
executor's state as a `mut` argument, which the compiler passed BY VALUE
and stored back when the call returned, erasing what a re-entrant path had
written to the same struct through its address. This builds a matrix of
small programs, runs each, and reads the unoptimized LLVM IR
(`mojo build --emit llvm`, which is KGEN's output before LLVM's own passes)
to say which shapes do that, and names two neighbouring mechanisms that
lose the same kind of write for other reasons:

  M1  A `mut` argument, `self` included, of a struct of 256 bytes or less
      is passed by value and returned: the caller loads the whole struct,
      calls, and stores the returned copy over it. Any write made to it
      through an address during the call is erased, whichever field.
  M2  A call that passes no pointer into the caller's frame is emitted as
      LLVM `tail call`, which promises the callee touches none of the
      caller's stack slots. A local whose address was handed out as an Int
      is then assumed unchanged across the call.
  M3  A `mut` argument over 256 bytes is passed as `ptr noalias`: fields
      the callee itself touches may be read stale, and its stores sunk,
      across a call that reaches the struct by address.

Every case writes `b = 42` through the struct's address inside the call
under test and then asks whether the write survived ("kept") or not
("lost"). M1 runs on a heap object whose address comes from an opaque
function, so M2 cannot be what loses it.

    uv run --no-sync python scripts/probes/mut_copyback_matrix.py
    ... -O 0          at -O0 nothing is lost: all three are optimizations
    ... --evidence    print the IR lines each verdict rests on
    ... --keep        keep the generated program and its IR

A characterisation, not a gate: it exits 0 whatever it finds, and 2 when
the matrix does not compile. docs/notes/mut-arguments-and-raw-addresses.md
is the rule this measures and what the tree does about it.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _sibling(name: str) -> str:
    near = Path(sys.executable).with_name(name)
    return str(near) if near.exists() else (shutil.which(name) or name)


MOJO = _sibling("mojo")

# M1's rows: name -> (size note, extra traits, payload fields, payload inits).
KINDS = {
    "Word2": ("16 B, two Ints", "", [], []),
    "Lists": ("64 B, List + String", "", ["var l: List[Int]", "var s: String"],
              ["self.l = List[Int]()", "self.s = String()"]),
    "Reg": ("16 B, TrivialRegisterPassable", ", TrivialRegisterPassable", [], []),
    "Max256": ("256 B", "", ["var arr: Array[Int, 30]"],
               ["self.arr = Array[Int, 30](fill=0)"]),
    "Over256": ("264 B", "", ["var arr: Array[Int, 31]"],
                ["self.arr = Array[Int, 31](fill=0)"]),
}

# M1's columns: shape -> (description, how the IR names the callee).
SHAPES = {
    "free": ("`@no_inline def f(mut s: T, ...)`", "free_{k}("),
    "method": ("`@no_inline def m(mut self, ...)`", "{k}::bump("),
    "raises": ("the same, `raises -> Bool`", "raises_{k}("),
    "generic": ("`def f[U: Trait](mut s: U, ...)`", "generic_bump["),
    "inline": ("`@always_inline`", "inline_{k}("),
    "escaped": ("the callee hands out `Pointer(to=s)`", "escaped_{k}("),
    "read": ("`def f(s: T, ...) -> Int`, read-only: what the CALLEE reads after the write", "read_{k}("),
    "ref": ("`def f(ref s: T, ...) -> Int`: what the callee reads after the write", "ref_{k}("),
    "pointer": ("`def f(p: Pointer[T, MutUntrackedOrigin], ...)`: the address, not the struct", "pointer_{k}("),
}

HEADER = '''from std.memory.alloc import unsafe_alloc


trait Bumpable:
    def bump_plain(mut self):
        ...

    @staticmethod
    def write(addr: Int):
        ...


def report(kind: String, shape: String, b: Int):
    print("RESULT", kind, shape, "kept" if b == 42 else "lost")


@no_inline
def generic_bump[U: Bumpable](mut s: U, addr: Int):
    s.bump_plain()
    U.write(addr)
'''

KIND = '''

struct {k}(Movable, Bumpable{traits}):
    var a: Int
    var b: Int
{fields}

    def __init__(out self):
        self.a = 0
        self.b = 0
{inits}

    @no_inline
    def bump(mut self, addr: Int):
        self.a += 1
        write_{k}(addr)

    def bump_plain(mut self):
        self.a += 1

    @staticmethod
    def write(addr: Int):
        write_{k}(addr)


@no_inline
def write_{k}(addr: Int):
    Pointer[{k}, MutUntrackedOrigin](unsafe_from_address=addr)[].b = 42


@no_inline
def make_{k}() -> Int:
    var h = unsafe_alloc[{k}](count=1)
    h.unsafe_write({k}())
    return Int(h)


@no_inline
def free_{k}(mut s: {k}, addr: Int):
    s.a += 1
    write_{k}(addr)


@no_inline
def raises_{k}(mut s: {k}, addr: Int) raises -> Bool:
    s.a += 1
    write_{k}(addr)
    return s.a > 0


@always_inline
def inline_{k}(mut s: {k}, addr: Int):
    s.a += 1
    write_{k}(addr)


@no_inline
def touch_a_{k}(own: Int):
    Pointer[{k}, MutUntrackedOrigin](unsafe_from_address=own)[].a += 1


@no_inline
def escaped_{k}(mut s: {k}, addr: Int):
    var own = Pointer(to=s)
    touch_a_{k}(Pointer(to=own).unsafe_bitcast[Int]()[])
    write_{k}(addr)


@no_inline
def read_{k}(s: {k}, addr: Int) -> Int:
    write_{k}(addr)
    return s.b


@no_inline
def ref_{k}(ref s: {k}, addr: Int) -> Int:
    write_{k}(addr)
    return s.b


@no_inline
def pointer_{k}(p: Pointer[{k}, MutUntrackedOrigin], addr: Int):
    p[].a += 1
    write_{k}(addr)


@no_inline
def run_{k}() raises:
    var addr = make_{k}()
    ref s = Pointer[{k}, MutUntrackedOrigin](unsafe_from_address=addr)[]
    s.b = 0
    report("{k}", "read", read_{k}(s, addr))
    s.b = 0
    report("{k}", "ref", ref_{k}(s, addr))
    s.b = 0
    pointer_{k}(Pointer[{k}, MutUntrackedOrigin](unsafe_from_address=addr), addr)
    report("{k}", "pointer", s.b)
    s.b = 0
    free_{k}(s, addr)
    report("{k}", "free", s.b)
    s.b = 0
    s.bump(addr)
    report("{k}", "method", s.b)
    s.b = 0
    _ = raises_{k}(s, addr)
    report("{k}", "raises", s.b)
    s.b = 0
    generic_bump(s, addr)
    report("{k}", "generic", s.b)
    s.b = 0
    inline_{k}(s, addr)
    report("{k}", "inline", s.b)
    s.b = 0
    escaped_{k}(s, addr)
    report("{k}", "escaped", s.b)
'''

# M2 and M3 ride on `Word2` and on `Wide` (536 B, so `ptr noalias`).
TAIL = '''

@no_inline
def write_framed(addr: Int, frame: Array[Int, 64]):
    Pointer[Word2, MutUntrackedOrigin](unsafe_from_address=addr)[].b = (
        42 + frame[0]
    )


@no_inline
def m2_stack_by_name():
    var s = Word2()
    var p = Pointer(to=s)
    var addr = Pointer(to=p).unsafe_bitcast[Int]()[]
    s.b = 0
    write_Word2(addr)
    report("M2", "stack_by_name", s.b)


@no_inline
def m2_stack_by_address():
    var s = Word2()
    var p = Pointer(to=s)
    var addr = Pointer(to=p).unsafe_bitcast[Int]()[]
    ref st = Pointer[Word2, MutUntrackedOrigin](unsafe_from_address=addr)[]
    st.b = 0
    write_Word2(addr)
    report("M2", "stack_by_address", st.b)


@no_inline
def m2_stack_frame_arg():
    var s = Word2()
    var p = Pointer(to=s)
    var addr = Pointer(to=p).unsafe_bitcast[Int]()[]
    var frame = Array[Int, 64](fill=0)
    s.b = 0
    write_framed(addr, frame)
    report("M2", "stack_frame_arg", s.b)


@no_inline
def m2_heap():
    var addr = make_Word2()
    ref st = Pointer[Word2, MutUntrackedOrigin](unsafe_from_address=addr)[]
    st.b = 0
    write_Word2(addr)
    report("M2", "heap", st.b)


struct Wide(Movable):
    var a: Int
    var b: Int
    var seen: Int
    var arr: Array[Int, 64]

    def __init__(out self):
        self.a = 0
        self.b = 0
        self.seen = 0
        self.arr = Array[Int, 64](fill=0)


@no_inline
def make_wide() -> Int:
    var h = unsafe_alloc[Wide](count=1)
    h.unsafe_write(Wide())
    return Int(h)


@no_inline
def wide_write_b(addr: Int):
    Pointer[Wide, MutUntrackedOrigin](unsafe_from_address=addr)[].b = 42


@no_inline
def wide_observe_a(addr: Int):
    ref s = Pointer[Wide, MutUntrackedOrigin](unsafe_from_address=addr)[]
    s.seen = s.a


@no_inline
def m3_read_twice(mut s: Wide, addr: Int) -> Int:
    var before = s.b
    wide_write_b(addr)
    return s.b - before


@no_inline
def m3_store_sunk(mut s: Wide, addr: Int):
    s.a = 7
    wide_observe_a(addr)
    s.a = 9


@no_inline
def m3_untouched(mut s: Wide, addr: Int):
    s.a += 1
    wide_write_b(addr)


@no_inline
def run_m3():
    var addr = make_wide()
    ref s = Pointer[Wide, MutUntrackedOrigin](unsafe_from_address=addr)[]
    s.b = 0
    report("M3", "read_twice", m3_read_twice(s, addr))
    s.seen = 0
    m3_store_sunk(s, addr)
    report("M3", "store_sunk", 42 if s.seen == 7 else 0)
    s.b = 0
    m3_untouched(s, addr)
    report("M3", "untouched", s.b)
'''

M2_CASES = {
    "stack_by_name": ("a local, read by name after the call", "write_Word2("),
    "stack_by_address": ("a local, read back through the Int address", "write_Word2("),
    "stack_frame_arg": ("as the first, the call also passes a frame pointer", "write_framed("),
    "heap": ("a heap object reached only by address", "write_Word2("),
}

M3_CASES = {
    "read_twice": "the callee reads `b` before the call and again after it",
    "store_sunk": "the callee stores `a`, the call reads it by address, the callee stores again",
    "untouched": "the call writes `b`, which the callee never touches",
}


def source() -> str:
    parts = [HEADER]
    for k, (_, traits, fields, inits) in KINDS.items():
        parts.append(KIND.format(
            k=k, traits=traits,
            fields="\n".join("    " + f for f in fields),
            inits="\n".join("        " + i for i in inits),
        ))
    parts.append(TAIL)
    parts.append("\n\ndef main() raises:\n")
    for k in KINDS:
        parts.append(f"    run_{k}()\n")
    for case in M2_CASES:
        parts.append(f"    m2_{case}()\n")
    parts.append("    run_m3()\n")
    return "".join(parts)


def build(td: Path, opt: int) -> tuple[str, str]:
    """Compile the matrix twice: an optimized binary and unoptimized IR."""
    src = td / "matrix.mojo"
    src.write_text(source())
    env = dict(os.environ, UV_NO_SYNC="1")
    exe = td / "matrix"
    for args in (["-O", str(opt), "-o", str(exe)],
                 ["-O", str(opt), "--emit", "llvm", "-o", str(td / "matrix.ll")]):
        proc = subprocess.run([MOJO, "build", str(src), *args],
                              capture_output=True, text=True, env=env)
        if proc.returncode != 0:
            print(proc.stderr[-4000:], file=sys.stderr)
            print(f"the matrix did not compile ({src})", file=sys.stderr)
            sys.exit(2)
    run = subprocess.run([str(exe)], capture_output=True, text=True)
    return run.stdout, (td / "matrix.ll").read_text()


def defines(ir: str) -> dict[str, str]:
    """Each defined function's symbol -> its `define` line."""
    out = {}
    for line in ir.splitlines():
        if line.startswith("define "):
            m = re.search(r'@"([^"]+)"', line)
            if m:
                out[m.group(1)] = line
    return out


def body_of(ir: str, symbol: str) -> list[str]:
    """The lines of one function's body in the IR. KGEN may append
    `_REMOVED_ARG` to a symbol whose signature it rewrote, so match the
    name as a prefix of the quoted symbol."""
    m = re.search(r'^define [^\n]*@"' + re.escape(symbol) + r'[^"]*"\(', ir, re.M)
    if m is None:
        return []
    end = ir.find("\n}\n", m.start())
    return ir[m.start():end].splitlines()


def passing(define: str) -> str:
    """How a `define` line takes its first argument: by value and returned
    (the copy-back), by value only (a snapshot), or as a pointer."""
    params = define[define.index('"(') + 2:]
    returned = define[len("define "):define.index(' @"')]
    if params.startswith("{"):
        agg = params[: params.index("} noundef") + 1] if "} noundef" in params else params
        return "by value, returned" if agg in returned else "by value"
    if params.startswith("ptr noalias"):
        return "ptr noalias"
    if params.startswith("ptr"):
        return "ptr"
    return "?"


def m1_symbol(defs: dict[str, str], k: str, shape: str) -> str | None:
    """The callee's symbol. A generic callee is named by its type argument,
    and a `ref` argument makes the function parametric on its origin, so
    its name is followed by `[` rather than `(`."""
    needle = "matrix::" + SHAPES[shape][1].format(k=k)
    for sym in defs:
        if shape == "generic":
            if sym.startswith(needle) and f"instref<matrix::{k}>" in sym:
                return sym
        elif sym.startswith(needle) or sym.startswith(needle[:-1] + "["):
            return sym
    return None


def results(out: str) -> dict[tuple[str, str], str]:
    return {(k, s): v for k, s, v in re.findall(r"RESULT (\S+) (\S+) (\w+)", out)}


def _split_top(s: str) -> list[str]:
    """Split on commas at nesting depth 0 over (), [], {} and <>."""
    out, depth, cur = [], 0, []
    for ch in s:
        depth += (ch in "([{<") - (ch in ")]}>")
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return out


def _bracketed(s: str, i: int) -> str:
    """The text inside the parenthesis opening at `s[i]`."""
    depth = 0
    for j in range(i, len(s)):
        depth += (s[j] == "(") - (s[j] == ")")
        if depth == 0:
            return s[i + 1:j]
    return s[i + 1:]


def census(path: str) -> int:
    """M1 in a real program's IR: every function that takes a struct by
    value and returns an aggregate containing it -- the promoted `mut` (or
    `ref`) argument's shape. A function that takes a value `var` and
    returns one of the same type has that shape too, so the count is an
    upper bound; the tree's own types are listed for reading against the
    source. Emit the IR with the build's own flags, e.g.

        mojo build --emit llvm -I packages/m0-core/ -I packages/m0-http/ \\
          -I packages/m0-postgres/ -I packages/m0-wsgi/ \\
          -I packages/m0-wsgi/mount packages/m0-wsgi/m0serve.mojo -o m0serve.ll
    """
    tree = ("lightbug_http::", "m0_http::", "m0_wsgi::", "m0_host::", "m0serve",
            "src::", "m0_core::", "m0_postgres::")
    total, ours = 0, {}
    for line in Path(path).read_text().splitlines():
        if not line.startswith("define "):
            continue
        m = re.search(r'@"([^"]+)"', line)
        if not m:
            continue
        sym = m.group(1)
        returned = line[len("define "):line.index(' @"')]
        params = _split_top(_bracketed(line, line.index('"(') + 1))
        paren = sym.find("(")
        named = _split_top(_bracketed(sym, paren)) if paren >= 0 else []
        for idx, p in enumerate(params):
            if not p.startswith("{") or "} noundef" not in p:
                continue
            if p[: p.index("} noundef") + 1] not in returned:
                continue
            total += 1
            # KGEN appends what it adds -- a raising function's error slot,
            # an out-pointer -- so the symbol's types name the IR's from the
            # start. Fewer IR parameters than types means one was dropped
            # (a zero-sized argument), and then nothing lines up.
            mojo_type = named[idx] if idx < len(named) <= len(params) else "?"
            if sym.startswith(tree) and not mojo_type.startswith("::"):
                ours.setdefault(mojo_type, []).append(sym.split("(")[0].split("[")[0])
    print(f"{path}: {total} struct arguments passed by value and returned "
          "(an upper bound on promoted `mut`/`ref` arguments)\n")
    print("this tree's own types among them ($N is a generic parameter):\n")
    for t, fns in sorted(ours.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(fns):3d}  {t}")
        for fn in sorted(set(fns)):
            print(f"         {fn}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-O", dest="opt", type=int, default=3,
                    help="optimization level for both builds (default 3, the build default)")
    ap.add_argument("--evidence", action="store_true",
                    help="print the IR lines each verdict rests on")
    ap.add_argument("--keep", action="store_true", help="keep the generated program")
    ap.add_argument("--source", action="store_true", help="print the generated program and exit")
    ap.add_argument("--census", metavar="IR_FILE",
                    help="instead: list M1's shape in a real program's unoptimized IR")
    args = ap.parse_args()
    if args.source:
        print(source())
        return 0
    if args.census:
        return census(args.census)

    td = Path(tempfile.mkdtemp(prefix="mut-copyback-"))
    try:
        out, ir = build(td, args.opt)
        got = results(out)
        defs = defines(ir)
        version = subprocess.run([MOJO, "--version"], capture_output=True, text=True).stdout.strip()
        print(f"{version}, -O{args.opt}: a write through the struct's address during the call,")
        print("then read after it. Cells: how the IR passes the argument; kept or lost at run time.\n")

        print("M1 -- `mut` argument, struct on the heap, reached only by address:\n")
        print("| struct | " + " | ".join(SHAPES) + " |")
        print("|---|" + "---|" * len(SHAPES))
        for k, (note, *_rest) in KINDS.items():
            cells = []
            for shape in SHAPES:
                sym = m1_symbol(defs, k, shape)
                how = passing(defs[sym]) if sym else "inlined"
                cells.append(f"{how}: {got.get((k, shape), '?')}")
            print(f"| {k} ({note}) | " + " | ".join(cells) + " |")
        print()
        for shape, (desc, _) in SHAPES.items():
            print(f"  {shape}: {desc}")

        print("\nM2 -- an Int address of the struct handed to a call:\n")
        print("| case | the call | result |")
        print("|---|---|---|")
        for case, (desc, callee) in M2_CASES.items():
            lines = [l for l in body_of(ir, f"matrix::m2_{case}()") if callee in l and "call" in l]
            marker = "`tail call`" if lines and "tail call" in lines[0] else "`call`"
            print(f"| {desc} | {marker} | {got.get(('M2', case), '?')} |")

        print("\nM3 -- `mut` argument over 256 bytes (`ptr noalias`):\n")
        print("| case | result |")
        print("|---|---|")
        for case, desc in M3_CASES.items():
            print(f"| {desc} | {got.get(('M3', case), '?')} |")

        if args.evidence:
            print("\nIR evidence (unoptimized, KGEN's output):")
            for k in ("Word2", "Over256"):
                sym = m1_symbol(defs, k, "method")
                print(f"\n  {defs[sym][:220]}")
            run = body_of(ir, "matrix::run_Word2()")
            for i, line in enumerate(run):
                if "@\"matrix::free_Word2(" in line and "call" in line:
                    print("\n  the caller of free_Word2 (load the struct, call, store it back):")
                    for l in run[i - 1:i + 2]:
                        print("   " + l.strip()[:200])
                    break
            for case in ("stack_by_name", "stack_frame_arg"):
                for l in body_of(ir, f"matrix::m2_{case}()"):
                    if ("write_Word2(" in l or "write_framed(" in l) and "call" in l:
                        print(f"\n  m2_{case}: {l.strip()[:200]}")
        if args.keep:
            print(f"\nkept: {td}")
    finally:
        if not args.keep:
            shutil.rmtree(td, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
