#!/usr/bin/env python3
"""The `_ = x` after an FFI call still pins the buffer that call reads.

Roughly thirty sites in this tree end a sequence with a bare `_ = x` --
`c/fdpass.mojo`'s `data` and `control`, `c/process.mojo`'s `argv`, `bufs`
and `path_c`, `m0-wsgi/src/bridge.mojo`'s `body`. They are there because
Mojo destroys a value at its last *tracked* use, and an address laundered
into a C argument is not one: without the line the allocator free is
emitted BEFORE the call that reads through the pointer. Nothing else in
CI would notice, and the failure lands in the `SCM_RIGHTS` hand-off under
`--workers N` as corruption with no symptom at the call site.

So this compiles `scripts/keepalive_probe.mojo` to LLVM IR and reads four
exported bodies. Two are the gate and two are a control:

    buffer_pinned   an owning List, `_ = data`   free AFTER the call
    buffer_bare     the same, line deleted       free BEFORE the call
    slot_pinned     a stack local's address      slot released after
    slot_bare       the same, line deleted       slot released after

The bare buffer arm is the load-bearing half. Without it the gate would
pass on a toolchain where neither form needed the keep-alive, and would
have stopped being evidence that the line does anything.

The control says the OTHER shape is not a hazard here: a plain stack slot
whose address escapes is kept alive by LLVM without help, so those
keep-alives are belt-and-braces. If it ever diverges, that changes. It is
an observation rather than a rule in the source, which is why `--sabotage`
has nothing to revert for it.

A failure is a FINDING -- compiler behaviour moved in the exact area this
repo's FFI safety rests on -- not gate noise. Each outcome prints what it
means for the tree.

`--sabotage` reverts each rule IN THE PROBE SOURCE, compiles that, and
insists this checker fails for every one, so a probe edited into agreeing
with itself is caught. It exists for the same reason
`scripts/shim_ownership.py --sabotage` does. It runs on `sabotage_lib.py`,
in memory (the probe on disk is never written): the unsabotaged probe must
pass first, and a sabotaged probe that does not compile is a MISS -- the
checker judged no IR -- where it used to count as caught (review B15).
`--sabotage --only LABEL` runs one rule.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

from sabotage_lib import DIAGNOSTIC, MOJO, Gate, Outcome, rule, run

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "scripts" / "keepalive_probe.mojo"

# The allocator free Mojo emits for an owning value, matched by shape
# rather than by its current KGEN name, which is not an API.
_FREE = re.compile(r"\bcall\b.*@[\w:$.\"\\]*[Ff]ree[\w:$.\"\\]*\(")
_LIFETIME_END = re.compile(r"@llvm\.lifetime\.end\b")
_ALLOCA = re.compile(r"=\s*alloca\b")
_CALL = re.compile(r"@poll\(")


class Finding(Exception):
    """A conclusion about the toolchain, not a crash."""


class CompileFailed(Finding):
    """The probe did not compile, so no IR was read. A finding for the check
    itself; for `--sabotage`, a sabotage that proved nothing."""


def compile_ir(source: str) -> str:
    """Compile probe `source` to LLVM IR, raising CompileFailed if it will not."""
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "keepalive_probe.mojo"
        src.write_text(source)
        out = Path(td) / "probe.ll"
        proc = subprocess.run(
            [MOJO, "build", "--emit", "llvm", str(src), "-o", str(out)],
            cwd=ROOT, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise CompileFailed(f"the probe did not compile:\n{proc.stderr}")
        return out.read_text()


def body(ir: str, name: str) -> list[str]:
    """The lines of one exported function's IR."""
    match = re.search(
        r"^define[^\n]*@" + re.escape(name) + r"\([^\n]*\n(.*?)\n\}",
        ir,
        re.S | re.M,
    )
    if match is None:
        raise Finding(
            f"no @{name} in the emitted IR -- did the probe lose the "
            'export, or its `abi("C")` effect?'
        )
    return match.group(1).splitlines()


def after_call(lines: list[str], name: str) -> list[str]:
    """The lines following the probe's one FFI call."""
    hits = [i for i, line in enumerate(lines) if _CALL.search(line)]
    if len(hits) != 1:
        raise Finding(
            f"@{name} has {len(hits)} calls to poll, expected exactly 1 -- "
            "the probe body changed shape"
        )
    return lines[hits[0] + 1 :]


def findings(ir: str) -> list[str]:
    """Everything wrong with `ir`, as sentences about what it means here."""
    out: list[str] = []

    for short, want in (("buffer_pinned", 1), ("buffer_bare", 0)):
        name = f"keepalive_probe_{short}"
        got = sum(1 for line in after_call(body(ir, name), name)
                  if _FREE.search(line))
        if got == want:
            continue
        if short == "buffer_pinned":
            out.append(
                "buffer_pinned frees BEFORE the call: `_ = x` no longer pins "
                "an owning value across an FFI call. Every such site in the "
                "tree is now a use-after-free -- audit them all before "
                "shipping, starting with c/fdpass.mojo and c/process.mojo."
            )
        else:
            out.append(
                "buffer_bare frees AFTER the call: the compiler now keeps an "
                "owning value alive without the keep-alive. The `_ = x` lines "
                "may be unnecessary -- but until someone establishes that, "
                "this gate is no longer evidence that they do anything."
            )

    for short in ("slot_pinned", "slot_bare"):
        name = f"keepalive_probe_{short}"
        lines = body(ir, name)
        allocas = sum(1 for line in lines if _ALLOCA.search(line))
        released = sum(1 for line in after_call(lines, name)
                       if _LIFETIME_END.search(line))
        if released < allocas:
            out.append(
                f"{short} ends {allocas - released} of its {allocas} stack "
                "slots BEFORE the call. A local whose address escapes to C is "
                "no longer kept alive by escape analysis alone, so the "
                "stack-slot keep-alives (c/fdpass.mojo's `iov`) stopped being "
                "belt-and-braces and became load-bearing. Audit them."
            )

    return out


# Each reverts one rule of the probe by matching EXACT source lines, so an
# edit that re-words them fails here as NOT APPLICABLE rather than
# quietly testing nothing.
SABOTAGES: list[tuple[str, str, str]] = [
    (
        "the pinned buffer keeps nothing alive",
        "        Int(data.unsafe_ptr()), n, c_int(0)\n    )\n    _ = data\n",
        "        Int(data.unsafe_ptr()), n, c_int(0)\n    )\n",
    ),
    (
        "the bare buffer arm is pinned too, so the pair agrees",
        "        Int(data.unsafe_ptr()), n, c_int(0)\n    )\n    return Int(rc)\n"
        "\n\n@export",
        "        Int(data.unsafe_ptr()), n, c_int(0)\n    )\n    _ = data\n"
        "    return Int(rc)\n\n\n@export",
    ),
    (
        "the gate's export is renamed away",
        '@export("keepalive_probe_buffer_pinned")',
        '@export("keepalive_probe_buffer_renamed")',
    ),
]


class Checker(Gate):
    """This checker, on the text it is handed. A probe that does not compile
    is `unbuilt` -- no IR was judged -- and every other Finding is the
    checker failing in its own words."""

    def run(self, texts) -> Outcome:
        try:
            ir = compile_ir(texts[PROBE])
        except CompileFailed as exc:
            said = DIAGNOSTIC.search(str(exc))
            return Outcome.unbuilt(said.group(0).strip() if said else str(exc).strip(),
                                   str(exc))
        try:
            found = findings(ir)
        except Finding as exc:
            return Outcome.failed(str(exc))
        return Outcome.failed(found[0]) if found else Outcome.passed()


def sabotage(argv: list[str]) -> int:
    """Every reverted rule must make this checker fail."""
    rules = [rule(label, PROBE, old, new) for label, old, new in SABOTAGES]
    return run("sabotage-keepalive", rules, Checker(), argv, write=False)


def main(argv: list[str]) -> int:
    if "--sabotage" in argv:
        return sabotage([a for a in argv if a != "--sabotage"])
    try:
        found = findings(compile_ir(PROBE.read_text()))
    except Finding as exc:
        print(f"keepalive-barrier: {exc}")
        return 1
    for line in found:
        print(f"keepalive-barrier: {line}")
    if found:
        return 1
    print(
        "keepalive-barrier: `_ = x` still pins an owning buffer across an FFI "
        "call, and deleting it still frees early; a stack slot whose address "
        "escapes survives either way"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
