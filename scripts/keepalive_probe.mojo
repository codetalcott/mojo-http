"""The counterfactual behind the `_ = x` keep-alives at this repo's FFI sites.

Never run: `main` prints and returns. This file exists to be compiled to
LLVM IR by `scripts/keepalive_barrier_check.py`, which reads the four
exported bodies below and asserts what each pair does.

**The hazard.** Mojo destroys a value at its last *tracked* use (ASAP
destruction), and an address handed to C is not one -- `unsafe_ptr()` and
`Pointer(to=x).unsafe_bitcast[Int]()[]` both erase the origin tying the
address back to the local. So an owning value can be released BEFORE the
call that reads through its pointer, and on this toolchain it is. A bare
`_ = x` after the call is a tracked use and moves the release back behind
it. Roughly thirty sites in this tree depend on that, among them
`c/fdpass.mojo`'s `data`/`control` (the `SCM_RIGHTS` hand-off under
`--workers N`), `c/process.mojo`'s `argv`/`bufs`/`path_c` (the `execv`
behind `--spawn-workers`) and `m0-wsgi/src/bridge.mojo`'s `body`.

**Two shapes, and only one of them is a hazard.** That split is the point
of having four functions rather than two:

  - **buffer** -- an OWNING value (`List`, `String`) whose `.unsafe_ptr()`
    crosses to C. The release is an allocator free that Mojo's frontend
    emits at the last tracked use, so nothing downstream can move it back:
    the bare arm frees before the call. This pair is the GATE.
  - **slot** -- a plain stack local whose ADDRESS is laundered to an
    integer and passed on, `c/fdpass.mojo`'s `iov`. There is nothing to
    free; the release is the slot's `llvm.lifetime.end`, and LLVM's own
    escape analysis sees the address stored and keeps the slot alive
    without help. Both arms are identical today. This pair is a CONTROL,
    and its keep-alives in the tree are belt-and-braces.

    Note what this is NOT: `src/signal.mojo`'s and `src/multiworker.mojo`'s
    `Pointer(to=handler).unsafe_bitcast[Int]()[]` LOADS the function value
    out of the local rather than taking the local's address, so nothing
    escapes there at all. The difference is one level of indirection and
    it is easy to misread, which is why the slot arm spells the escaping
    form out the way `fdpass.mojo` does -- a `Pointer` to the local, then
    the `Int` held in THAT pointer's own slot.

`poll` is the callee throughout because it takes an address as an integer
and this file is never executed; nothing here depends on what it does.
"""

from std.ffi import c_int, external_call


@export("keepalive_probe_buffer_pinned")
def keepalive_probe_buffer_pinned(n: Int) abi("C") -> Int:
    """An owning buffer, its pointer laundered through `Int`, kept alive."""
    var data = List[UInt8](unsafe_uninit_length=4096)
    var rc = external_call["poll", c_int, Int, Int, c_int](
        Int(data.unsafe_ptr()), n, c_int(0)
    )
    _ = data
    return Int(rc)


@export("keepalive_probe_buffer_bare")
def keepalive_probe_buffer_bare(n: Int) abi("C") -> Int:
    """The same, with the keep-alive deleted. Frees before the call."""
    var data = List[UInt8](unsafe_uninit_length=4096)
    var rc = external_call["poll", c_int, Int, Int, c_int](
        Int(data.unsafe_ptr()), n, c_int(0)
    )
    return Int(rc)


@export("keepalive_probe_slot_pinned")
def keepalive_probe_slot_pinned(n: Int) abi("C") -> Int:
    """A stack local whose ADDRESS crosses as an integer, kept alive."""
    var slot = UInt64(n)
    var slot_ptr = Pointer(to=slot)
    var rc = external_call["poll", c_int, Int, Int, c_int](
        Pointer(to=slot_ptr).unsafe_bitcast[Int]()[], n, c_int(0)
    )
    _ = slot
    return Int(rc)


@export("keepalive_probe_slot_bare")
def keepalive_probe_slot_bare(n: Int) abi("C") -> Int:
    """The same, with the keep-alive deleted. Identical today."""
    var slot = UInt64(n)
    var slot_ptr = Pointer(to=slot)
    var rc = external_call["poll", c_int, Int, Int, c_int](
        Pointer(to=slot_ptr).unsafe_bitcast[Int]()[], n, c_int(0)
    )
    return Int(rc)


def main():
    print(
        "scripts/keepalive_probe.mojo is compiled, not run --",
        "see scripts/keepalive_barrier_check.py",
    )
