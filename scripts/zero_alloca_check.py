#!/usr/bin/env python3
"""No stack buffer of zero bytes is handed to anything that could write it.

`stack_allocation[N, T]()` reserves N values of `T`. The fork's `c_void` is
`NoneType`, whose size is 0, so `inet_pton`'s `stack_allocation[4, c_void]()`
reserved nothing -- KGEN emits `alloca {}, i64 4`, zero bytes -- and C wrote
the address into it, over whatever the stack held beside it. Every
`ListenConfig.listen` went through it. Most layouts left the damage
harmless; the one review B27b's tests produced corrupted a String `listen`
was building and crashed with SIGSEGV. Review record B30 counted the buffer
in bytes. This is the check that keeps the next one out.

It reads two programs' unoptimized IR (`mojo build --emit llvm`):

    m0serve                 the whole binary, compiled as `build-serve` and
                            `check-copyback` compile it: the fork, m0_http,
                            m0_wsgi and m0_postgres, as far as the server
                            reaches them. Catches the next site anywhere
                            m0serve runs, not only in `inet_pton`.
    zero_alloca_probe.mojo  the fork's `inet_pton` for BOTH address
                            families, whatever m0serve reaches, and the
                            bare arm: the old shape, which must be refused.

A package precompile (what `check-fork-package` runs) emits no IR at all:
a generic body is lowered only where something instantiates it. So the
whole-tree scan is the whole shipped program's.

An `alloca` of a zero-size type -- `{}`, `[0 x T]`, a struct or array of
nothing but those -- is common and harmless: KGEN gives an empty struct a
slot, stores `{}` into it and loads `{}` back. m0serve has about sixty. One
is refused when:

    its count is not 1       `alloca {}, i64 4` asks for four values of
                             nothing: someone meant bytes;
    anything else touches it an argument to a call (C, or any function), a
                             pointer stored elsewhere, arithmetic on its
                             address, a non-empty value stored or loaded
                             through it. Its lifetime markers, a load or
                             store of the empty value itself and a memcpy
                             or memset of length 0 are the only uses that
                             cannot read or write a byte through it.

The bare arm is the load-bearing half: without it the check would pass on
a toolchain where `NoneType` had grown a byte or on a reading of the IR
that had stopped seeing allocas, and would have stopped being evidence.
Each run also requires both `inet_pton` instantiations in the probe and
the IPv4 one in m0serve, so a probe or a program that stopped reaching the
listen path is refused rather than read as clean. `--selftest` judges
canned IR for each rule without a compiler, and every run does that first.

    python3 scripts/zero_alloca_check.py              # emit both IRs, judge
    python3 scripts/zero_alloca_check.py --selftest   # canned IR only
    python3 scripts/zero_alloca_check.py --sabotage   # each rule reverted

`--sabotage` edits the tree through `sabotage_lib` (restored in `finally`):
`inet_pton`'s buffer is put back to `c_void` for each family, and the probe
is edited into agreeing with itself; the check must fail on every one,
naming the site.

Needs the packages' `.mojoc` files (`poe build-all`). Exit 0 when no
zero-size buffer escapes, 1 when one does, 2 when it cannot judge.
"""

from __future__ import annotations

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
PROBE = "scripts/zero_alloca_probe.mojo"
NETWORK = "packages/m0-http/lightbug_http/c/network.mojo"


def _sibling(name: str) -> str:
    near = Path(sys.executable).with_name(name)
    return str(near) if near.exists() else (shutil.which(name) or name)


MOJO = _sibling("mojo")

# build-serve's include path and entry file, as check-copyback reads them.
INCLUDES = ["packages/m0-core/", "packages/m0-http/", "packages/m0-postgres/",
            "packages/m0-wsgi/", "packages/m0-wsgi/mount"]
ENTRY = "packages/m0-wsgi/m0serve.mojo"
MOJOC = ["packages/m0-core/m0_core.mojoc", "packages/m0-http/m0_http.mojoc",
         "packages/m0-postgres/m0_postgres.mojoc", "packages/m0-wsgi/m0_wsgi.mojoc"]

BARE = "zero_alloca_probe_bare"
INET_PTON = re.compile(r"::c::network::inet_pton\[")


class CannotJudge(Exception):
    pass


# --- reading the IR ----------------------------------------------------------


def split_top(s: str) -> list[str]:
    """`s` split at the commas outside any bracket."""
    out, depth, cur = [], 0, []
    for ch in s:
        if ch in "{[<(":
            depth += 1
        elif ch in "}]>)":
            depth -= 1
        if ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    tail = "".join(cur).strip()
    if tail:
        out.append(tail)
    return out


def named_types(ir: str) -> dict[str, str]:
    return dict(re.findall(r"^(%[\w.$\"]+) = type (.+)$", ir, re.M))


def is_zero(t: str, named: dict[str, str], seen: frozenset = frozenset()) -> bool:
    """Whether LLVM type `t` has size 0."""
    t = t.strip()
    if t in named and t not in seen:
        return is_zero(named[t], named, seen | {t})
    if t.startswith("<{") and t.endswith("}>"):
        t = t[1:-1]
    if t.startswith("{") and t.endswith("}"):
        inner = t[1:-1].strip()
        return all(is_zero(f, named, seen) for f in split_top(inner)) if inner else True
    m = re.fullmatch(r"\[(\d+) x (.+)\]", t)
    if m:
        return m.group(1) == "0" or is_zero(m.group(2), named, seen)
    return False


@dataclass(frozen=True)
class Function:
    symbol: str
    lines: tuple[str, ...]


def functions(ir: str) -> list[Function]:
    """Every defined function and its body."""
    out, symbol, body = [], None, []
    for line in ir.splitlines():
        if symbol is None:
            if line.startswith("define "):
                m = re.search(r'@("(?:[^"\\]|\\.)*"|[\w.$]+)\(', line)
                symbol = (m.group(1).strip('"') if m else "?")
                body = []
            continue
        if line == "}":
            out.append(Function(symbol, tuple(body)))
            symbol = None
            continue
        body.append(line)
    return out


_ALLOCA = re.compile(r"^\s*(%[\w.]+) = alloca (.*)$")
_MEM = re.compile(r"@llvm\.mem(?:cpy|move|set)[\w.]*\((.*)\)")


@dataclass(frozen=True)
class Finding:
    symbol: str
    alloca: str
    why: str

    def sentence(self, where: str) -> str:
        return (f"{where}: a zero-size stack buffer in `{_short(self.symbol)}`: "
                f"`{self.alloca.strip()}` {self.why}")


def _short(symbol: str) -> str:
    return symbol if len(symbol) <= 160 else symbol[:157] + "..."


def _use_is_harmless(line: str, name: str, named: dict[str, str]) -> bool:
    """Whether `line`, which mentions `name`, can neither read nor write a
    byte through it."""
    s = line.strip()
    if "@llvm.lifetime." in s:
        return True
    m = re.match(r"%[\w.]+ = load (.*)$", s)
    if m:
        parts = split_top(m.group(1))
        return (len(parts) >= 2 and is_zero(parts[0], named)
                and parts[1] == f"ptr {name}")
    m = re.match(r"store (.*)$", s)
    if m:
        parts = split_top(m.group(1))
        if len(parts) < 2 or parts[1] != f"ptr {name}":
            return False  # the address itself is stored somewhere
        typed = parts[0].rsplit(" ", 1)
        return len(typed) == 2 and typed[1] != name and is_zero(typed[0], named)
    m = _MEM.search(s)
    if m:
        args = split_top(m.group(1))
        return len(args) >= 3 and args[2] in ("i64 0", "i32 0")
    return False


def _describe(line: str) -> str:
    s = line.strip()
    m = re.search(r"\bcall\b[^@]*@(\"(?:[^\"\\]|\\.)*\"|[\w.$]+)", s)
    if m:
        return f"is handed to `@{_short(m.group(1).strip(chr(34)))}`"
    m = re.match(r"(?:%[\w.]+ = )?(\w+)", s)
    return f"reaches a `{m.group(1) if m else s[:40]}`"


def findings_in(fn: Function, named: dict[str, str]) -> list[Finding]:
    out = []
    for line in fn.lines:
        m = _ALLOCA.match(line)
        if not m:
            continue
        name, rest = m.group(1), split_top(m.group(2))
        if not rest or not is_zero(rest[0], named):
            continue
        count = next((p for p in rest[1:] if re.fullmatch(r"i\d+ \S+", p)), "i64 1")
        whys = []
        if count.split()[1] != "1":
            whys.append(f"asks for `{count.split()[1]}` values of a zero-size type, "
                        "which is no bytes at all")
        mention = re.compile(re.escape(name) + r"(?![\w.])")
        for use in fn.lines:
            if use is line or not mention.search(use):
                continue
            if not _use_is_harmless(use, name, named):
                whys.append(f"{_describe(use)} (`{use.strip()[:120]}`), which may "
                            "write or read bytes through an address that owns none")
                break
        if whys:
            out.append(Finding(fn.symbol, line, "; and it ".join(whys)))
    return out


def findings(ir: str) -> tuple[list[Finding], list[Function]]:
    named = named_types(ir)
    fns = functions(ir)
    return [f for fn in fns for f in findings_in(fn, named)], fns


# --- the judgement -----------------------------------------------------------


def judge(program_ir: str, probe_ir: str) -> tuple[int, list[str]]:
    """(exit status, what it means), from the two IRs."""
    problems: list[str] = []
    fixed_hint = ("Count the buffer in bytes, as `inet_pton` does since review "
                  "B30: `stack_allocation[N, UInt8]()`, bitcast if the callee "
                  "wants `c_void`.")

    probe_found, probe_fns = findings(probe_ir)
    bare = [f for f in probe_found if f.symbol == BARE]
    if not any(fn.symbol == BARE for fn in probe_fns):
        problems.append(f"no @{BARE} in the probe's IR: the bare arm is gone, "
                        "so nothing shows this check can refuse anything")
    elif not bare:
        problems.append(
            f"the bare arm (@{BARE}) was NOT refused: `stack_allocation[4, "
            "c_void]()` handed to C no longer reads as a zero-size buffer. "
            "Either `NoneType` is no longer zero bytes on this toolchain or "
            "this check has stopped seeing allocas -- until someone finds out "
            "which, a pass here is not evidence")
    for f in probe_found:
        if f.symbol != BARE:
            problems.append(f.sentence("the probe") + ". " + fixed_hint)
    instantiated = {fn.symbol for fn in probe_fns if INET_PTON.search(fn.symbol)}
    if len(instantiated) < 2:
        problems.append(
            f"the probe instantiates {len(instantiated)} `inet_pton`(s), expected "
            "one per address family: it no longer reads what it claims to")

    program_found, program_fns = findings(program_ir)
    for f in program_found:
        problems.append(f.sentence("m0serve") + ". " + fixed_hint)
    if not any(INET_PTON.search(fn.symbol) for fn in program_fns):
        problems.append("m0serve's IR holds no `inet_pton`: the scan no longer "
                        "reaches the listen path it exists for")

    if problems:
        return 1, problems
    return 0, [
        f"no zero-size buffer escapes in m0serve ({len(program_fns)} functions) "
        f"or the probe's two `inet_pton`s, and the bare arm is refused: "
        f"{bare[0].why.split(';')[0]}"
    ]


# --- selftest ------------------------------------------------------------------


def _fn(symbol: str, body: str) -> str:
    return f'define internal i32 @"{symbol}"() #0 {{\n{body}\n}}\n'


def _selftest_cases() -> list[tuple[str, str, int]]:
    """(label, IR, how many findings)."""
    harmless = ("  %1 = alloca {}, i64 1, align 1\n"
                "  call void @llvm.lifetime.start.p0(ptr %1)\n"
                "  store {} undef, ptr %1, align 1\n"
                "  %2 = load {}, ptr %1, align 1\n"
                "  call void @llvm.memcpy.p0.p0.i64(ptr %3, ptr %1, i64 0, i1 false)\n"
                "  call void @llvm.lifetime.end.p0(ptr %1)\n  ret i32 0")
    return [
        ("an empty struct's slot, stored, loaded and copied as nothing",
         _fn("ok", harmless), 0),
        ("a real buffer handed to C",
         _fn("ok", "  %1 = alloca i8, i64 4, align 1\n"
                   "  %2 = call i32 @inet_pton(i32 2, ptr %0, ptr %1)\n  ret i32 %2"), 0),
        ("the old inet_pton: four of nothing, handed to C",
         _fn("old", "  %3 = alloca {}, i64 4, align 1\n"
                    "  call void @llvm.lifetime.start.p0(ptr %3)\n"
                    "  %50 = call i32 @inet_pton(i32 2, ptr %49, ptr %3)\n  ret i32 %50"), 1),
        ("four of nothing, never used",
         _fn("count", "  %3 = alloca {}, i64 4, align 1\n  ret i32 0"), 1),
        ("one of nothing, handed to C",
         _fn("one", "  %3 = alloca {}, i64 1, align 1\n"
                    "  %4 = call i32 @inet_pton(i32 2, ptr %2, ptr %3)\n  ret i32 %4"), 1),
        ("a zero-length array, handed to a Mojo function",
         _fn("arr", "  %3 = alloca [0 x i8], align 1\n"
                    '  call void @"m::f"(ptr %3)\n  ret i32 0'), 1),
        ("an empty struct of empty structs, its address stored",
         _fn("st", "  %3 = alloca { {}, [0 x i64] }, i64 1, align 8\n"
                   "  store ptr %3, ptr %7, align 8\n  ret i32 0"), 1),
        ("four real bytes stored into nothing",
         _fn("wr", "  %3 = alloca {}, i64 1, align 1\n"
                   "  store i32 5, ptr %3, align 4\n  ret i32 0"), 1),
        ("a real value loaded out of nothing",
         _fn("rd", "  %3 = alloca {}, i64 1, align 1\n"
                   "  %4 = load i64, ptr %3, align 8\n  ret i32 0"), 1),
        ("its address taken apart",
         _fn("gep", "  %3 = alloca {}, i64 1, align 1\n"
                    "  %4 = getelementptr i8, ptr %3, i64 2\n  ret i32 0"), 1),
        ("a copy of four bytes out of nothing",
         _fn("cp", "  %3 = alloca {}, i64 1, align 1\n"
                   "  call void @llvm.memcpy.p0.p0.i64(ptr %9, ptr %3, i64 4, i1 false)\n"
                   "  ret i32 0"), 1),
        ("a named type that is empty",
         '%T = type { {} }\n'
         + _fn("named", "  %3 = alloca %T, i64 2, align 1\n  ret i32 0"), 1),
        ("a name that only starts like the slot's",
         _fn("prefix", "  %3 = alloca {}, i64 1, align 1\n"
                       "  %30 = call i32 @inet_pton(i32 2, ptr %2, ptr %31)\n  ret i32 0"), 0),
    ]


def selftest() -> int:
    bad = 0
    for label, ir, want in _selftest_cases():
        got = len(findings(ir)[0])
        ok = got == want
        bad += not ok
        print(f"  {'ok  ' if ok else 'FAIL'}  {label}: {got} finding(s), expected {want}")

    inet = ('lightbug_http::c::network::inet_pton[lightbug_http::c::address::'
            'AddressFamily](::String$),address_family={}')
    good_probe = (_fn(inet.format(2), "  ret i32 0") + _fn(inet.format(24), "  ret i32 0")
                  + _fn(BARE, "  %3 = alloca {}, i64 4, align 1\n"
                              "  %4 = call i32 @inet_pton(i32 2, ptr %2, ptr %3)\n"
                              "  ret i32 %4"))
    good_program = _fn(inet.format(2), "  %3 = alloca i8, i64 4, align 1\n  ret i32 0")
    old_program = _fn(inet.format(2), "  %3 = alloca {}, i64 4, align 1\n"
                                      "  %4 = call i32 @inet_pton(i32 2, ptr %2, ptr %3)\n"
                                      "  ret i32 %4")
    judged = [
        ("the tree as it is", good_program, good_probe, 0, ""),
        ("m0serve's inet_pton put back", old_program, good_probe, 1,
         "m0serve: a zero-size stack buffer in `lightbug_http::c::network::inet_pton"),
        ("the bare arm mended", good_program,
         good_probe.replace("alloca {}, i64 4", "alloca i8, i64 4"), 1, "was NOT refused"),
        ("the bare arm deleted", good_program,
         good_probe.replace(BARE, "renamed"), 1, "the bare arm is gone"),
        ("the probe's IPv6 instantiation gone", good_program,
         good_probe.replace("address_family=24", "address_family=2"), 1,
         "one per address family"),
        ("m0serve without the listen path", _fn("x", "  ret i32 0"), good_probe, 1,
         "no longer reaches the listen path"),
    ]
    for label, program, probe, want, says in judged:
        rc, lines = judge(program, probe)
        ok = rc == want and (not says or any(says in ln for ln in lines))
        bad += not ok
        print(f"  {'ok  ' if ok else 'FAIL'}  judge, {label}: exit {rc}, expected {want}"
              + ("" if ok else f" -- said {lines}"))
    print("zero-alloca selftest: " + ("OK" if not bad else f"{bad} FAILED"))
    return 1 if bad else 0


# --- emitting ------------------------------------------------------------------


def target_cpu() -> str:
    """build-serve's baseline CPU, so the IR is the shipped binary's."""
    system, machine = platform.system(), platform.machine()
    if system == "Darwin":
        return "apple-m1" if machine == "arm64" else "x86-64-v2"
    return "generic" if machine == "aarch64" else "x86-64-v2"


def emit(entry: str, out: Path) -> float:
    cmd = [MOJO, "build", "--target-cpu", target_cpu(), "--emit", "llvm"]
    for inc in INCLUDES:
        cmd += ["-I", inc]
    cmd += [entry, "-o", str(out)]
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="13.0")
    start = time.monotonic()
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, env=env)
    if proc.returncode != 0 or not out.exists():
        raise CannotJudge(f"`{' '.join(cmd[1:])}` failed (exit {proc.returncode}):\n"
                          + (proc.stderr or proc.stdout)[-3000:])
    return time.monotonic() - start


def check() -> int:
    import contextlib
    import io

    with contextlib.redirect_stdout(io.StringIO()) as quiet:
        broken = selftest()
    if broken:
        print("CANNOT JUDGE: the check's own selftest fails:\n" + quiet.getvalue())
        return 2
    missing = [p for p in MOJOC if not (ROOT / p).exists()]
    if missing:
        print(f"CANNOT JUDGE: no {', '.join(missing)}: run `poe build-all` first")
        return 2
    td = Path(tempfile.mkdtemp(prefix="zero-alloca-"))
    try:
        spent = emit(ENTRY, td / "m0serve.ll")
        spent += emit(PROBE, td / "probe.ll")
        start = time.monotonic()
        rc, lines = judge((td / "m0serve.ll").read_text(), (td / "probe.ll").read_text())
    except CannotJudge as e:
        print(f"CANNOT JUDGE: {e}")
        return 2
    finally:
        shutil.rmtree(td, ignore_errors=True)
    for line in lines:
        print(f"zero-alloca: {line}")
    print(f"  ({spent:.0f} s compiling, {time.monotonic() - start:.1f} s reading)")
    return rc


# --- sabotage ------------------------------------------------------------------

# Each reverts one rule by matching EXACT source lines; an edit that re-words
# them fails as NOT APPLICABLE rather than quietly testing nothing.
SABOTAGES = [
    ("inet_pton's IPv4 buffer is four c_voids again", NETWORK,
     "        ip_buffer = stack_allocation[4, UInt8]().unsafe_bitcast[c_void]()\n",
     "        ip_buffer = stack_allocation[4, c_void]()\n",
     "zero-size stack buffer in `lightbug_http::c::network::inet_pton"),
    ("inet_pton's IPv6 buffer is sixteen c_voids again", NETWORK,
     "        ip_buffer = stack_allocation[16, UInt8]().unsafe_bitcast[c_void]()\n",
     "        ip_buffer = stack_allocation[16, c_void]()\n",
     "zero-size stack buffer in `lightbug_http::c::network::inet_pton"),
    ("the bare arm is mended, so the probe agrees with itself", PROBE,
     "    var buffer = stack_allocation[4, c_void]()\n",
     "    var buffer = stack_allocation[4, UInt8]().unsafe_bitcast[c_void]()\n",
     "was NOT refused"),
    ("the probe stops instantiating IPv6", PROBE,
     '        return UInt32(inet_pton[AddressFamily.AF_INET6](String("::1")).bytes[15])\n',
     '        return UInt32(inet_pton[AddressFamily.AF_INET](String("::1")).bytes[15])\n',
     "one per address family"),
]


def sabotage(argv: list[str]) -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    from sabotage_lib import DIAGNOSTIC, Gate, Outcome, rule, run, run_command

    class Checker(Gate):
        """This check, on the tree as the harness left it on disk."""

        def run(self, texts) -> Outcome:
            ran = run_command([sys.executable, __file__], timeout=1800)
            if ran.returncode == 0:
                return Outcome.passed(ran.output)
            if ran.returncode == 1:
                said = [ln for ln in ran.output.splitlines() if ln.startswith("zero-alloca:")]
                return Outcome.failed(said[0] if said else ran.output[-300:], ran.output)
            diagnostic = DIAGNOSTIC.search(ran.output)
            if diagnostic:
                return Outcome.unbuilt(diagnostic.group(0).strip(), ran.output)
            return Outcome.unclear(f"exit {ran.returncode}: {ran.output[-300:]}", ran.output)

    rules = [rule(label, path, old, new, expect=expect)
             for label, path, old, new, expect in SABOTAGES]
    return run("sabotage-zero-alloca", rules, Checker(), argv)


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()
    if "--sabotage" in argv:
        return sabotage([a for a in argv if a != "--sabotage"])
    try:
        return check()
    except Exception:
        # A crash must not exit 1, which says a zero-size buffer escapes.
        import traceback

        traceback.print_exc()
        print("CANNOT JUDGE: the check itself failed")
        return 2


if __name__ == "__main__":
    os.chdir(ROOT)
    sys.exit(main(sys.argv[1:]))
