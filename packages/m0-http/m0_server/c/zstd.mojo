"""The zstd binding, opened at run time: the library, its entry points,
and the stream compressor a compressed SSE stream writes through
(docs/notes/compressing-a-stream.md).

libzstd is never linked. `zstd_library` opens it on first use under
m0-sqlite's loader rules (`packages/m0-sqlite/src/lib.mojo`), each found
there or in m0-postgres by crashing:

  - **The handle and the pointers loaded from it live in ONE struct**
    (`ZstdLibrary`). A `thin` pointer loaded from a handle carries no
    borrow, so a handle held anywhere else is `dlclose`d at its last
    mention and the next call jumps into unmapped memory.
  - **A `thin` pointer FIELD is called only from a method beside it.**
    Every entry point is private behind a wrapper in `ZstdFns`.
  - **The library is never unloaded once opened.** One handle per process,
    opened `RTLD_NOW | RTLD_LOCAL`, is published in a global word
    (`_library_slot`) and never closed, so a `ZstdFns` copied out of it
    stays valid for the life of the process. That is what makes it sound
    for every compressor to hold its own copy of the table.

Two copies of libzstd in one process are harmless, unlike libsqlite3: a
context is only ever used through the table that made it. So there is no
second-image refusal. The handle is local all the same, so this copy never
captures the calls of one something else loads (SPEC O24's reason).

`M0_LIBZSTD` names the file outright; otherwise `default_search_path`. An
absent library is one error naming every path tried. A library that is not
libzstd, or a libzstd older than 1.4.0, where the parameter API and
`ZSTD_compressStream2` became stable, is refused by name.

This module imports nothing from the fork, as `fcntl.mojo` does not, so the
event loop and `m0_http`'s `sse_response` can both reach it.
"""

from std.atomic import Atomic
from std.collections.string.string_span import _get_kgen_string
from std.ffi import OwnedDLHandle, c_int
from std.memory import Pointer
from std.memory.alloc import unsafe_alloc
from std.os import getenv
from std.sys import CompilationTarget


comptime ZSTD_MIN_VERSION: Int = 10400
"""The floor: libzstd 1.4.0, as `ZSTD_versionNumber` spells it."""

comptime DEFAULT_LEVEL: Int = 1
"""3.1 ms of CPU per MB on the blobs stream, against 3.9 at level 3, and at
the same window a third of level 3's memory (the note's measurements)."""

comptime DEFAULT_WINDOW_LOG: Int = 15
"""A 32 KB window: a context holds about 200 KB, and the measured stream
whose markup repeats does so within 16 KB. A wider window is a decision
for a measured stream that wants one."""

comptime _ZSTD_E_FLUSH = c_int(1)
"""`ZSTD_e_flush`: everything given so far, out as a block that decodes on
arrival."""

comptime _ZSTD_E_END = c_int(2)
"""`ZSTD_e_end`: flush, and close the frame."""

comptime _ZSTD_C_COMPRESSION_LEVEL = c_int(100)
comptime _ZSTD_C_WINDOW_LOG = c_int(101)
comptime _ZSTD_D_WINDOW_LOG_MAX = c_int(100)

comptime _FIRST_OUTPUT_CAP: Int = 32768
"""The most a push allocates before it knows it needs more. An event is a
few KB, so this is one round; a larger push grows between rounds."""


# --- The C signatures ------------------------------------------------------
#
# Contexts (`ZSTD_CCtx *`, `ZSTD_DCtx *`) and the buffer structs'
# addresses as Int; `size_t` as Int; `unsigned` as UInt32. Each is
# zstd.h's declaration, transcribed.

comptime _VersionFn = def () thin abi("C") -> UInt32
"""`unsigned ZSTD_versionNumber(void)`"""
comptime _IsErrorFn = def (Int) thin abi("C") -> UInt32
"""`unsigned ZSTD_isError(size_t)`"""
comptime _ErrorNameFn = def (Int) thin abi("C") -> Int
"""`const char *ZSTD_getErrorName(size_t)`"""
comptime _CreateFn = def () thin abi("C") -> Int
"""`ZSTD_CCtx *ZSTD_createCCtx(void)`, and the `DCtx` twin."""
comptime _FreeFn = def (Int) thin abi("C") -> Int
"""`size_t ZSTD_freeCCtx(ZSTD_CCtx *)`, and the `DCtx` twin."""
comptime _SetParameterFn = def (Int, c_int, c_int) thin abi("C") -> Int
"""`size_t ZSTD_CCtx_setParameter(ZSTD_CCtx *, ZSTD_cParameter, int)`, and
the `DCtx` twin."""
comptime _CompressStreamFn = def (Int, Int, Int, c_int) thin abi("C") -> Int
"""`size_t ZSTD_compressStream2(ZSTD_CCtx *, ZSTD_outBuffer *,
ZSTD_inBuffer *, ZSTD_EndDirective)`"""
comptime _DecompressStreamFn = def (Int, Int, Int) thin abi("C") -> Int
"""`size_t ZSTD_decompressStream(ZSTD_DStream *, ZSTD_outBuffer *,
ZSTD_inBuffer *)`"""
comptime _SizeofFn = def (Int) thin abi("C") -> Int
"""`size_t ZSTD_sizeof_CCtx(const ZSTD_CCtx *)`"""


def _open_flags() -> Int:
    """`RTLD_NOW | RTLD_LOCAL`. `OwnedDLHandle`'s default is `RTLD_GLOBAL`,
    so the mode is spelled; `RTLD_LOCAL` is 0 in glibc's `dlfcn.h` and 4 in
    macOS's."""
    comptime if CompilationTarget.is_macos():
        return 2 | 4
    else:
        return 2


def _checked[
    T: TrivialRegisterPassable
](ref handle: OwnedDLHandle, name: StaticString, path: String) raises -> T:
    """Resolve one entry point, or raise naming the symbol that is missing.

    Asked with `check_symbol` first, so a library that is not libzstd is an
    error naming what it lacks rather than whatever the lookup does with a
    missing name.
    """
    if not handle.check_symbol(String(name)):
        raise Error(
            "the library at " + path + " has no symbol `" + String(name)
            + "`: it is not libzstd, or a libzstd older than 1.4.0, the"
            " oldest this binding supports"
        )
    return handle.borrow().get_function[T](String(name))


def default_search_path() -> List[String]:
    """Where to look for libzstd when `M0_LIBZSTD` does not say.

    The bare name first, which the loader resolves from its own cache. Then
    the places a distribution or a package manager puts it: macOS ships no
    libzstd, and Homebrew's directory is not on dyld's default fallback
    path. The whole list appears in the error when none of them opens.
    """
    var out = List[String]()
    comptime if CompilationTarget.is_macos():
        out.append("libzstd.1.dylib")
        out.append("/opt/homebrew/lib/libzstd.1.dylib")
        out.append("/usr/local/lib/libzstd.1.dylib")
        out.append("/opt/local/lib/libzstd.1.dylib")
    else:
        out.append("libzstd.so.1")
        out.append("/usr/lib/x86_64-linux-gnu/libzstd.so.1")
        out.append("/usr/lib/aarch64-linux-gnu/libzstd.so.1")
        out.append("/usr/lib64/libzstd.so.1")
        out.append("/usr/local/lib/libzstd.so.1")
    return out^


def zstd_candidates() -> List[String]:
    """`M0_LIBZSTD` alone when it is set, else `default_search_path`."""
    var from_env = getenv("M0_LIBZSTD", "")
    if from_env:
        var out = List[String]()
        out.append(from_env)
        return out^
    return default_search_path()


struct ZstdFns(ImplicitlyCopyable, Movable):
    """Every libzstd entry point this binding calls, and the wrapper for each.

    The one place an entry point is added: its signature above, then a
    field, a load and a wrapper here. Implicitly copyable because it owns
    nothing, only addresses into a library that is never unloaded (the
    module docstring's third rule), so every compressor holds a copy.
    """

    var _version_number: _VersionFn
    var _is_error: _IsErrorFn
    var _error_name: _ErrorNameFn
    var _create_cctx: _CreateFn
    var _free_cctx: _FreeFn
    var _cctx_set_parameter: _SetParameterFn
    var _compress_stream2: _CompressStreamFn
    var _sizeof_cctx: _SizeofFn
    var _create_dctx: _CreateFn
    var _free_dctx: _FreeFn
    var _dctx_set_parameter: _SetParameterFn
    var _decompress_stream: _DecompressStreamFn
    """Every entry point, private: the module docstring's second rule."""

    def __init__(out self, ref handle: OwnedDLHandle, path: String) raises:
        """Resolve every entry point from `handle`, checking each first."""
        self._version_number = _checked[_VersionFn](handle, "ZSTD_versionNumber", path)
        self._is_error = _checked[_IsErrorFn](handle, "ZSTD_isError", path)
        self._error_name = _checked[_ErrorNameFn](handle, "ZSTD_getErrorName", path)
        self._create_cctx = _checked[_CreateFn](handle, "ZSTD_createCCtx", path)
        self._free_cctx = _checked[_FreeFn](handle, "ZSTD_freeCCtx", path)
        self._cctx_set_parameter = _checked[_SetParameterFn](
            handle, "ZSTD_CCtx_setParameter", path
        )
        self._compress_stream2 = _checked[_CompressStreamFn](
            handle, "ZSTD_compressStream2", path
        )
        self._sizeof_cctx = _checked[_SizeofFn](handle, "ZSTD_sizeof_CCtx", path)
        self._create_dctx = _checked[_CreateFn](handle, "ZSTD_createDCtx", path)
        self._free_dctx = _checked[_FreeFn](handle, "ZSTD_freeDCtx", path)
        self._dctx_set_parameter = _checked[_SetParameterFn](
            handle, "ZSTD_DCtx_setParameter", path
        )
        self._decompress_stream = _checked[_DecompressStreamFn](
            handle, "ZSTD_decompressStream", path
        )

    def version_number(self) -> Int:
        """`ZSTD_versionNumber`: major*10000 + minor*100 + release."""
        return Int(self._version_number())

    def is_error(self, code: Int) -> Bool:
        """`ZSTD_isError`: whether a `size_t` result is an error code."""
        return self._is_error(code) != 0

    def error_name(self, code: Int) -> String:
        """`ZSTD_getErrorName`: the library's words for an error code."""
        var p = Pointer[UInt8, MutAnyOrigin](unsafe_from_address=self._error_name(code))
        if Int(p) == 0:
            return String("unknown error")
        var n = 0
        while p[unsafe_offset=n] != 0:
            n += 1
        return String(unsafe_from_utf8=Span(unsafe_ptr=p, length=n))

    def create_cctx(self) -> Int:
        return self._create_cctx()

    def free_cctx(self, cctx: Int):
        _ = self._free_cctx(cctx)

    def cctx_set_parameter(self, cctx: Int, param: c_int, value: c_int) -> Int:
        return self._cctx_set_parameter(cctx, param, value)

    def compress_stream2(self, cctx: Int, output: Int, input: Int, end: c_int) -> Int:
        return self._compress_stream2(cctx, output, input, end)

    def sizeof_cctx(self, cctx: Int) -> Int:
        return self._sizeof_cctx(cctx)

    def create_dctx(self) -> Int:
        return self._create_dctx()

    def free_dctx(self, dctx: Int):
        _ = self._free_dctx(dctx)

    def dctx_set_parameter(self, dctx: Int, param: c_int, value: c_int) -> Int:
        return self._dctx_set_parameter(dctx, param, value)

    def decompress_stream(self, dctx: Int, output: Int, input: Int) -> Int:
        return self._decompress_stream(dctx, output, input)


struct ZstdLibrary(Movable):
    """An open libzstd: the handle, which file it is, and every entry point.

    One struct on purpose, the module docstring's first rule: the table
    lives and moves with the handle it was loaded from.
    """

    var _lib: OwnedDLHandle
    """First field, and the reason this struct exists."""

    var path: String
    """Which file was opened, reported and never guessed at."""

    var fns: ZstdFns
    """Every entry point, called through `ZstdFns`' wrappers."""

    def __init__(out self, var handle: OwnedDLHandle, var path: String, fns: ZstdFns):
        self.fns = fns
        self.path = path^
        # Last, so the handle's own last mention is after every load.
        self._lib = handle^


def open_zstd(candidates: List[String]) raises -> ZstdLibrary:
    """Open the first candidate that opens, and check it is a libzstd this
    binding can use.

    The first candidate that opens is the answer or the error: a library
    that opens and is refused is reported, never passed over for the next.
    Everything is asked of the library before the first branch that can
    raise, so a refused library closes as the raise begins with no table of
    it kept. Publishes nothing: `zstd_library` is what keeps one.
    """
    var tried = List[String]()
    for candidate in candidates:
        var handle: OwnedDLHandle
        try:
            handle = OwnedDLHandle(candidate, _open_flags())
        except:
            tried.append(candidate)
            continue
        var fns = ZstdFns(handle, candidate)
        var have = fns.version_number()
        if have < ZSTD_MIN_VERSION:
            raise Error(
                "the libzstd at " + candidate + " is version " + String(have)
                + ", older than the 1.4.0 (" + String(ZSTD_MIN_VERSION)
                + ") this binding requires"
            )
        return ZstdLibrary(handle^, candidate, fns)

    var names = String("")
    for i in range(len(tried)):
        names += ("\n  " if i else "") + tried[i]
    raise Error(
        "libzstd could not be opened. Set M0_LIBZSTD to the library file, or"
        " install one where it can be found. Tried:\n  " + names
    )


@no_inline
def _library_slot() -> Pointer[Int, MutUntrackedOrigin]:
    """Return the word holding the address of the process's `ZstdLibrary`,
    0 until the first compressor.

    `@no_inline` IS LOAD-BEARING: `pop.global_alloc` is `Pure`, so an
    inlined copy of this accessor would make a word of its own (m0-http's
    `src/global_slot.mojo` holds the measurement), and every copy would open
    the library again.
    """
    return {
        _mlir_value = __mlir_op.`pop.global_alloc`[
            name = _get_kgen_string["m0_http_zstd_library"](),
            count = Int(1).__mlir_index__(),
            _type = Pointer[Int, MutUntrackedOrigin]._mlir_type,
            alignment = Int(8).__mlir_index__(),
        ]()
    }


def zstd_library() raises -> ZstdFns:
    """The process's libzstd table, opening the library on first use.

    The record is published by compare-and-swap, because `M0_THREADS` loops
    can open their first compressed streams together. The loser drops its
    own record, whose handle closing unmaps nothing while the winner's is
    open, and takes the winner's. The winner's record is never freed and
    its handle never closed.
    """
    var word = Pointer[Atomic[Int64], MutUntrackedOrigin](
        unsafe_from_address=Int(_library_slot())
    )
    var current = Int(word[].load())
    if current == 0:
        var record = unsafe_alloc[ZstdLibrary](count=1)
        record.unsafe_write(open_zstd(zstd_candidates()))
        var expected = Int64(0)
        if word[].compare_exchange(expected, Int64(Int(record))):
            current = Int(record)
        else:
            _ = record.unsafe_take_pointee()
            record.unsafe_free()
            current = Int(expected)
    return Pointer[ZstdLibrary, MutUntrackedOrigin](unsafe_from_address=current)[].fns


struct ZstdCompressor(Movable):
    """One zstd frame, written a flushed block at a time: one stream's
    context, for the life of the stream.

    Not `Copyable`: it owns a `ZSTD_CCtx`, freed when the compressor is.
    Each `push` returns bytes the client can decode on arrival, and every
    push after the first is compressed against what the earlier ones sent,
    within the window, which is where a stream's ratio comes from.
    """

    var _fns: ZstdFns
    var _cctx: Int
    var _bufs: List[Int]
    """`ZSTD_outBuffer` then `ZSTD_inBuffer`, three words each (`dst` or
    `src`, `size`, `pos`), in one list whose storage never moves."""
    var _ended: Bool

    def __init__(
        out self, level: Int = DEFAULT_LEVEL, window_log: Int = DEFAULT_WINDOW_LOG
    ) raises:
        """A context at `level`, its window `1 << window_log` bytes.

        A parameter the library refuses (a window log outside 10 to 31, a
        level it does not have) raises with the library's words, and the
        context is freed before the raise.
        """
        var fns = zstd_library()
        var cctx = fns.create_cctx()
        if cctx == 0:
            raise Error("zstd: ZSTD_createCCtx returned NULL")
        var rc = fns.cctx_set_parameter(cctx, _ZSTD_C_COMPRESSION_LEVEL, c_int(level))
        if not fns.is_error(rc):
            rc = fns.cctx_set_parameter(cctx, _ZSTD_C_WINDOW_LOG, c_int(window_log))
        if fns.is_error(rc):
            var why = fns.error_name(rc)
            fns.free_cctx(cctx)
            raise Error(
                "zstd: level " + String(level) + ", window log "
                + String(window_log) + " refused: " + why
            )
        self._fns = fns
        self._cctx = cctx
        self._bufs = List[Int](length=6, fill=0)
        self._ended = False

    def __deinit__(deinit self):
        self._fns.free_cctx(self._cctx)

    def push(mut self, data: Span[UInt8, _], end: Bool = False) raises -> List[UInt8]:
        """Compress `data` and flush it: the bytes to put on the wire.

        `end=True` closes the frame instead, after which the compressor
        refuses another push. Calls `ZSTD_compressStream2` until it returns
        0 with the input consumed, growing the output between calls:
        zstd.h's rule is that a nonzero return is bytes still held, and
        only 0 means the flush is complete.
        """
        if self._ended:
            raise Error("zstd: push after the frame was ended")
        var directive = _ZSTD_E_END if end else _ZSTD_E_FLUSH
        var bound = len(data) + (len(data) >> 7) + 128
        var out = List[UInt8](capacity=min(bound, _FIRST_OUTPUT_CAP))
        var written = 0
        var base = Int(self._bufs.unsafe_ptr())
        self._bufs[3] = Int(data.unsafe_ptr())
        self._bufs[4] = len(data)
        self._bufs[5] = 0
        while True:
            self._bufs[0] = Int(out.unsafe_ptr()) + written
            self._bufs[1] = out.capacity() - written
            self._bufs[2] = 0
            var rc = self._fns.compress_stream2(self._cctx, base, base + 24, directive)
            if self._fns.is_error(rc):
                raise Error("zstd: " + self._fns.error_name(rc))
            written += self._bufs[2]
            out._len = written
            if rc == 0 and self._bufs[5] == self._bufs[4]:
                break
            out.reserve(out.capacity() * 2)
        if end:
            self._ended = True
        return out^

    def memory(self) -> Int:
        """`ZSTD_sizeof_CCtx`: the bytes this context holds now."""
        return self._fns.sizeof_cctx(self._cctx)


struct ZstdDecompressor(Movable):
    """The other end of a `ZstdCompressor`, for the tests: each `push`
    returns everything the bytes so far complete."""

    var _fns: ZstdFns
    var _dctx: Int
    var _bufs: List[Int]
    var frame_complete: Bool
    """Whether the last `push` ended on a complete frame: what a stream's
    farewell, pushed with `end=True`, leaves behind it."""

    def __init__(out self, window_log_max: Int = 0) raises:
        """A decoding context; `window_log_max`, when not 0, refuses a frame
        that declares a larger window (`ZSTD_d_windowLogMax`)."""
        var fns = zstd_library()
        var dctx = fns.create_dctx()
        if dctx == 0:
            raise Error("zstd: ZSTD_createDCtx returned NULL")
        if window_log_max:
            var rc = fns.dctx_set_parameter(
                dctx, _ZSTD_D_WINDOW_LOG_MAX, c_int(window_log_max)
            )
            if fns.is_error(rc):
                var why = fns.error_name(rc)
                fns.free_dctx(dctx)
                raise Error("zstd: window log max " + String(window_log_max) + " refused: " + why)
        self._fns = fns
        self._dctx = dctx
        self._bufs = List[Int](length=6, fill=0)
        self.frame_complete = False

    def __deinit__(deinit self):
        self._fns.free_dctx(self._dctx)

    def push(mut self, data: Span[UInt8, _]) raises -> List[UInt8]:
        """Decode `data`: every byte it completes, and none it does not."""
        var out = List[UInt8](capacity=max(4 * len(data), 4096))
        var written = 0
        var base = Int(self._bufs.unsafe_ptr())
        self._bufs[3] = Int(data.unsafe_ptr())
        self._bufs[4] = len(data)
        self._bufs[5] = 0
        while True:
            self._bufs[0] = Int(out.unsafe_ptr()) + written
            self._bufs[1] = out.capacity() - written
            self._bufs[2] = 0
            var rc = self._fns.decompress_stream(self._dctx, base, base + 24)
            if self._fns.is_error(rc):
                raise Error("zstd: " + self._fns.error_name(rc))
            written += self._bufs[2]
            out._len = written
            # 0 is zstd.h's word for "a frame is completely decoded".
            self.frame_complete = rc == 0
            if self._bufs[5] == self._bufs[4] and self._bufs[2] < self._bufs[1]:
                break
            out.reserve(out.capacity() * 2)
        return out^
