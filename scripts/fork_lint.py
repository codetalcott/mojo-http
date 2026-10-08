#!/usr/bin/env python3
"""Two mechanical defects of the lightbug fork, refused by text.

1. A variadic libc function called through `external_call` outside its
   sanctioned wrapper. Darwin arm64 passes ALL variadic arguments on the
   stack, so a fixed-argument declaration (`external_call["shm_open", c_int,
   ptr, c_int, c_int]`) hands the callee stack garbage for its mode (review
   record LF17: a shared page created with mode 0o0, 0o1 and 0o744). The
   shape that works is `c/fcntl.mojo`'s `_fcntl`: dummies fill x0-x7 so the
   variadic arguments land on the stack. The list of variadic symbols is
   VARIADIC below, one place; SANCTIONED names the one file that may call
   each (SANCTIONED_LINUX_ONLY: the `syscall` of `epoll_pwait2_ns`, never
   compiled on Darwin). A new variadic call means a new SANCTIONED entry, which is a review
   of the call's shape, and a mention in `c/fcntl.mojo`'s docstring, which
   names every variadic libc symbol the program calls (checked here).
   Scope: every `.mojo` under packages/, apps/, scripts/ and packaging/, since
   the ABI hazard is not the fork's alone. m0-sqlite and m0-postgres call C
   through `dlopen`, not `external_call`, and are outside what this reads.

2. A `[byte=` slice in the fork (`packages/m0-http/lightbug_http/`). It
   asserts a codepoint boundary at both ends, a trap rather than an error
   on a request's non-UTF-8 bytes (SPEC G14). ALLOWED_BYTE_SLICES lists the
   sites that are safe, each keyed by file and a snippet of the line (never
   a line number) with the reason its string cannot hold request bytes.
   It is empty: the fork holds no such slice. An entry that matches nothing
   is refused, so the list cannot rot.

Comments, docstrings and string literals are not code, and are not read.

    python3 scripts/fork_lint.py            # lint the tree
    python3 scripts/fork_lint.py --selftest # each rule refuses a planted
                                            # violation and passes a clean one
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# libc functions declared variadic (`...`) in their headers.
VARIADIC = frozenset([
    "fcntl", "fcntl64", "open", "open64", "openat", "openat64", "creat64",
    "ioctl", "shm_open", "sem_open", "mq_open", "semctl", "msgctl", "prctl",
    "ptrace", "syscall", "printf", "fprintf", "dprintf", "sprintf",
    "snprintf", "scanf", "sscanf", "fscanf", "syslog", "execl", "execle",
    "execlp",
])

# variadic symbol -> the files (relative to ROOT) that may call it, each in
# `_fcntl`'s shape (Darwin: dummies fill x0-x7, the variadic argument last).
SANCTIONED = {
    "fcntl": ["packages/m0-http/lightbug_http/c/fcntl.mojo"],
    "shm_open": ["packages/m0-http/lightbug_http/c/process.mojo"],
}

# Variadic symbols called on Linux only, where a variadic integer or pointer
# argument travels as a fixed one does (x86-64 SysV, AAPCS64-Linux), so no
# Darwin dummies are needed. Their files carry the argument for it, and the
# call is never compiled on Darwin: `epoll_pwait2_ns` documents `syscall`.
SANCTIONED_LINUX_ONLY = {
    "syscall": ["packages/m0-http/lightbug_http/c/epoll.mojo"],
}

# The file whose docstring names every sanctioned symbol.
DOC_FILE = "packages/m0-http/lightbug_http/c/fcntl.mojo"

FORK = "packages/m0-http/lightbug_http/"

# (file, snippet of the code line) -> why that string cannot hold request
# bytes. Empty: lane C converted the last request-string slice.
ALLOWED_BYTE_SLICES = {}

SCAN_DIRS = ["packages", "apps", "scripts", "packaging"]


def code_only(src, keep_strings):
    """`src` with comments and triple-quoted strings blanked (newlines
    kept, so line numbers hold), and with ordinary string literals blanked
    too unless `keep_strings`."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "#":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
        elif c in "\"'":
            q = c * 3
            if src.startswith(q, i):
                j = i + 3
                while j < n and not src.startswith(q, j):
                    j += 2 if src[j] == "\\" else 1
                j = min(j + 3, n)
                out.append("".join("\n" if ch == "\n" else " " for ch in src[i:j]))
                i = j
            else:
                j = i + 1
                while j < n and src[j] != c and src[j] != "\n":
                    j += 2 if src[j] == "\\" else 1
                j = min(j + 1, n)
                seg = src[i:j]
                out.append(seg if keep_strings else " " * len(seg))
                i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


_CALL = re.compile(r'external_call\s*\[\s*"(\w+)"')


def check_variadic(rel, src):
    """Findings for one file: variadic `external_call`s outside SANCTIONED."""
    code = code_only(src, keep_strings=True)
    found = []
    for m in _CALL.finditer(code):
        sym = m.group(1)
        if sym in VARIADIC and rel not in SANCTIONED.get(sym, []) + SANCTIONED_LINUX_ONLY.get(sym, []):
            line = code.count("\n", 0, m.start()) + 1
            found.append(
                f"{rel}:{line}: external_call[\"{sym}\"] -- `{sym}` is variadic and "
                f"Darwin arm64 passes variadic arguments on the stack; declare it "
                f"in the shape of c/fcntl.mojo's `_fcntl` and sanction it in "
                f"scripts/fork_lint.py SANCTIONED"
            )
    return found


def check_byte_slices(rel, src, allowed):
    """Findings for one fork file: `[byte=` in code outside `allowed`;
    also the keys of `allowed` this file matched, to retire the stale."""
    code = code_only(src, keep_strings=False)
    found, used = [], set()
    for ln, text in enumerate(code.split("\n"), 1):
        if "[byte=" not in text:
            continue
        key = next((k for k in allowed if k[0] == rel and k[1] in text), None)
        if key:
            used.add(key)
        else:
            found.append(
                f"{rel}:{ln}: `[byte=` slice -- it asserts a codepoint boundary, a trap "
                f"on a request's non-UTF-8 bytes (SPEC G14); slice as "
                f"String(unsafe_from_utf8=s.as_bytes()[a:b]), or allow it in "
                f"scripts/fork_lint.py ALLOWED_BYTE_SLICES with its reason"
            )
    return found, used


def mojo_files(root):
    for d in SCAN_DIRS:
        base = root / d
        if base.is_dir():
            for p in sorted(base.rglob("*.mojo")):
                if not any(part in (".pixi", ".venv", "node_modules") for part in p.parts):
                    yield p


def check_docstring(doc_src):
    doc = doc_src.split('"""')[1] if doc_src.count('"""') >= 2 else ""
    return [
        f"{DOC_FILE}: the module docstring does not name `{sym}`, a variadic "
        f"symbol SANCTIONED lets the program call"
        for sym in SANCTIONED
        if sym not in doc
    ]


def lint(root):
    problems, used = [], set()
    for p in mojo_files(root):
        rel = p.relative_to(root).as_posix()
        src = p.read_text(encoding="utf-8", errors="replace")
        problems += check_variadic(rel, src)
        if rel.startswith(FORK):
            f, u = check_byte_slices(rel, src, ALLOWED_BYTE_SLICES)
            problems += f
            used |= u
    for key in ALLOWED_BYTE_SLICES:
        if key not in used:
            problems.append(f"ALLOWED_BYTE_SLICES entry {key} matches no line: delete it")
    for rels in [*SANCTIONED.values(), *SANCTIONED_LINUX_ONLY.values()]:
        for rel in rels:
            if not (root / rel).is_file():
                problems.append(f"SANCTIONED names {rel}, which does not exist")
    doc = root / DOC_FILE
    if doc.is_file():
        problems += check_docstring(doc.read_text(encoding="utf-8"))
    return problems


def selftest():
    fails = []

    def expect(name, got, want):
        if bool(got) != want:
            fails.append(f"{name}: expected {'a finding' if want else 'none'}, got {got}")

    fixed_shm = (
        'def f(name: String):\n'
        '    return external_call[\n'
        '        "shm_open", c_int, Int, c_int, c_int\n'
        '    ](0, 1, 2)\n'
    )
    f = check_variadic("packages/m0-http/lightbug_http/c/socket.mojo", fixed_shm)
    expect("fixed-argument shm_open outside its wrapper", f, True)
    expect("... and it names the line", f and ":2:" in f[0], True)
    expect("shm_open in its sanctioned file",
           check_variadic("packages/m0-http/lightbug_http/c/process.mojo", fixed_shm), False)
    expect("fcntl in the wrong file",
           check_variadic("apps/x/a.mojo", 'external_call["fcntl", c_int, c_int, c_int]()'), True)
    expect("open in an app",
           check_variadic("apps/x/a.mojo", 'external_call["open", c_int, Int]()'), True)
    expect("ioctl in a test",
           check_variadic("packages/m0-http/test/t.mojo", 'external_call["ioctl", c_int]()'), True)
    expect("syscall in its Linux-only file",
           check_variadic("packages/m0-http/lightbug_http/c/epoll.mojo", 'external_call["syscall", Int]()'), False)
    expect("syscall elsewhere",
           check_variadic("packages/m0-http/lightbug_http/c/socket.mojo", 'external_call["syscall", Int]()'), True)
    expect("a fixed-arity symbol",
           check_variadic("apps/x/a.mojo", 'external_call["socketpair", c_int, c_int]()'), False)
    expect("a variadic name in a comment",
           check_variadic("apps/x/a.mojo", '# external_call["open", c_int]()\n'), False)
    expect("a variadic name in a docstring",
           check_variadic("apps/x/a.mojo", '"""\nexternal_call["open", c_int]()\n"""\n'), False)
    expect("a name that merely starts with a variadic one",
           check_variadic("apps/x/a.mojo", 'external_call["opendir", c_int]()'), False)

    bad = 'def g(target: String):\n    return String(target[byte=1:3])\n'
    f, _ = check_byte_slices("packages/m0-http/lightbug_http/uri.mojo", bad, {})
    expect("a [byte= slice of a request string", f, True)
    expect("... and it names the line", f and ":2:" in f[0], True)
    expect("a slice in a comment",
           check_byte_slices("f.mojo", "# never s[byte=a:b]\n", {})[0], False)
    expect("a slice in a docstring",
           check_byte_slices("f.mojo", '"""never s[byte=a:b]"""\nx = 1\n', {})[0], False)
    expect("a slice in a string literal",
           check_byte_slices("f.mojo", 'var s = "[byte=" + x\n', {})[0], False)
    expect("a clean byte slice",
           check_byte_slices("f.mojo", "var s = String(unsafe_from_utf8=b[1:3])\n", {})[0], False)
    allowed = {("f.mojo", "HEX[byte="): "a constant table"}
    f, used = check_byte_slices("f.mojo", "out += HEX[byte=1:2]\n", allowed)
    expect("an allowlisted constant-table slice", f, False)
    expect("... marks its entry used", len(used) == 1, True)
    f, _ = check_byte_slices("g.mojo", "out += HEX[byte=1:2]\n", allowed)
    expect("an allowlist key is per file", f, True)
    expect("a docstring missing a sanctioned symbol", check_docstring('"""fcntl only"""'), True)
    expect("a docstring naming them all",
           check_docstring('"""' + " ".join(SANCTIONED) + '"""'), False)
    if fails:
        print("fork_lint selftest FAILED:\n  " + "\n  ".join(fails))
        return 1
    print("fork_lint selftest: every rule refuses its planted violation and passes a clean sample")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    problems = lint(ROOT)
    if problems:
        print("fork_lint: " + str(len(problems)) + " finding(s)")
        for p in problems:
            print("  " + p)
        return 1
    print("fork_lint: no variadic libc symbol called outside its wrapper, no `[byte=` slice in the fork")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
