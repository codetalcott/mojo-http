"""Whether this process image carries MAX's parallel runtime.

One fact, read by the Mojo host (`host_checks`, SPEC E32) and by m0serve
(its pre-bind refusal and its doctor, SPEC E33), so the two cannot answer
it differently: `fork()` copies the calling thread alone and the runtime's
worker threads are started before `main`, so a `parallelize` in a forked
worker never returns. Both refuse the fork before the bind; m0serve's
escape is `--spawn-workers`, whose worker execs and starts the runtime
fresh (docs/notes/threads-first-for-m0-apps.md,
docs/notes/m0serve-and-the-runtime-a-fork-cannot-carry.md).

Nothing here imports MAX. The question is asked of the loaded images.
"""

from std.ffi import OwnedDLHandle, external_call
from std.memory import Pointer
from std.sys.info import CompilationTarget


comptime PARALLEL_RUNTIME_IMAGE = "libAsyncRTMojoBindings"
"""The image MAX's parallel runtime lives in, without its extension.

`max.algorithm.parallelize` links it (`NEEDED` on Linux, an install name on
macOS); a binary that imports nothing from MAX does not carry it. That
makes the image the fact `host_checks` asks about: not "does the
application call `parallelize`", which nothing outside the application
can know, but "could it", which the loaded images answer.
"""

# glibc's: the Linux branch of `parallel_runtime_linked` alone reads them.
# macOS spells RTLD_NOLOAD as 0x10, which is why that branch walks dyld's
# image list instead of asking `dlopen`.
comptime _RTLD_LAZY = 1
comptime _RTLD_NOLOAD = 4


def _image_name(addr: Int) -> String:
    """A String from the NUL-terminated path dyld owns; "" for NULL."""
    if addr == 0:
        return String("")
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    var n = 0
    while p[unsafe_offset=n] != 0:
        n += 1
    if n == 0:
        return String("")
    return String(unsafe_from_utf8=Span(unsafe_ptr=p, length=n))


def _names_image(path: String, image: String) -> Bool:
    """Whether `path`'s last segment is `image` plus an extension --
    `.../libAsyncRTMojoBindings.dylib` -- and not a look-alike."""
    var bytes = path.as_bytes()
    var start = 0
    for i in range(len(bytes)):
        if bytes[i] == UInt8(ord("/")):
            start = i + 1
    var leaf = String(unsafe_from_utf8=bytes[start:])
    return leaf.startswith(image + ".")


def parallel_runtime_linked() -> Bool:
    """Whether this process image carries MAX's parallel runtime.

    The fact behind `workers-vs-parallel-runtime`: `fork()` copies the
    calling thread alone, and the runtime's worker threads are started
    before `main`, so a forked worker inherits the runtime's bookkeeping
    and none of its workers -- a `parallelize` there never returns.
    Measured in every shape, a parent that never called it included, and
    a request that hung took its worker's loop and the shutdown with it
    (docs/notes/threads-first-for-m0-apps.md). Asked of the loaded
    images, never by calling anything of MAX's: this package imports
    nothing from it, and an application that links it is refused prefork
    before the bind rather than served into a hang.

    Linux: `dlopen` with `RTLD_NOLOAD` answers a handle for an image that
    is already mapped, matched by soname, and maps nothing for one that is
    not. macOS: dyld's own image list, walked by leaf name, because its
    `RTLD_NOLOAD` is another bit and matches a bare name less predictably.

    A fact about the PROCESS, which is the point for a built binary and a
    trap under `mojo run`: there the program runs inside the compiler's
    process, which maps the runtime once MAX is installed beside the
    toolchain, so a JIT'd test reads "linked" whether or not its source
    imports MAX (measured: True under `mojo run` with `max-core` synced,
    False for the same source built and run). The tests pin the fact
    rather than assume the venv.
    """
    comptime if CompilationTarget.is_macos():
        var count = Int(external_call["_dyld_image_count", UInt32]())
        for i in range(count):
            var addr = external_call["_dyld_get_image_name", Int](UInt32(i))
            if _names_image(_image_name(addr), PARALLEL_RUNTIME_IMAGE):
                return True
        return False
    else:
        try:
            var handle = OwnedDLHandle(
                String(PARALLEL_RUNTIME_IMAGE, ".so"), _RTLD_LAZY | _RTLD_NOLOAD
            )
            _ = handle^
            return True
        except:
            return False
