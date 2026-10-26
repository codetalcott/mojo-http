"""Tests for the zstd binding a compressed stream writes through
(`lightbug_http/c/zstd.mojo`; docs/notes/compressing-a-stream.md, step 2).

libzstd is opened at run time, so these run under `mojo run` with nothing
linked. An absent library FAILS them, naming every path tried: every Linux
runner has libzstd (`dpkg` depends on it) and a Mac has Homebrew's, so a
skip would be green having tested nothing.
"""

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from lightbug_http.c.zstd import (
    DEFAULT_WINDOW_LOG, ZSTD_MIN_VERSION, ZstdCompressor, ZstdDecompressor,
    open_zstd, zstd_library,
)


def _event(i: Int) -> List[UInt8]:
    """An SSE event shaped like a whole-state frame: the same markup each
    time, with a number that changes."""
    var s = String(
        "event: datastar-patch-elements\n"
        "data: elements <ul id=\"board\" class=\"board\">"
        "<li class=\"cell\" data-on:click=\"@post('/cell')\">"
    )
    s += String(i)
    s += String("</li><li class=\"cell\">seat</li></ul>\n\n")
    return List[UInt8](s.as_bytes())


def _noise(n: Int, seed: UInt64) -> List[UInt8]:
    """`n` bytes of xorshift output: data zstd cannot shrink."""
    var out = List[UInt8](capacity=n)
    var x = seed
    for _ in range(n):
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        out.append(UInt8(x & 0xFF))
    return out^


def test_library_opens_at_or_above_the_floor() raises:
    var fns = zstd_library()
    assert_true(fns.version_number() >= ZSTD_MIN_VERSION)


def test_one_frame_round_trips() raises:
    var c = ZstdCompressor()
    var d = ZstdDecompressor()
    var a = List[UInt8](String("first half, ").as_bytes())
    var b = List[UInt8](String("second half").as_bytes())
    var wire = List[UInt8]()
    wire.extend(Span(c.push(Span(a))))
    wire.extend(Span(c.push(Span(b), end=True)))
    var back = d.push(Span(wire))
    assert_equal(String(unsafe_from_utf8=Span(back)), "first half, second half")


def test_each_flush_decodes_as_it_arrives() raises:
    """The decoder fed each push's bytes yields exactly that push, which is
    what lets a client see each event when it lands; and the shared context
    is what makes the stream small."""
    var c = ZstdCompressor()
    var d = ZstdDecompressor()
    var raw = 0
    var sent = 0
    for i in range(200):
        var ev = _event(i)
        var wire = c.push(Span(ev))
        raw += len(ev)
        sent += len(wire)
        var back = d.push(Span(wire))
        assert_equal(len(back), len(ev))
        for j in range(len(ev)):
            if back[j] != ev[j]:
                assert_true(False, "event " + String(i) + " decoded wrong at byte " + String(j))
    # One context across 200 events of repeated markup: well past what
    # compressing each event alone gives (about 3:1 on the seat's stream).
    assert_true(sent * 8 < raw, "ratio " + String(raw) + "/" + String(sent))


def test_a_push_larger_than_one_round_of_output() raises:
    """1 MB that will not compress overflows the first output round, so
    this exercises the loop on a nonzero return."""
    var c = ZstdCompressor()
    var d = ZstdDecompressor()
    var data = _noise(1 << 20, 0x9E3779B97F4A7C15)
    var wire = c.push(Span(data), end=True)
    assert_true(len(wire) > len(data) // 2)
    var back = d.push(Span(wire))
    assert_equal(len(back), len(data))
    for j in range(len(data)):
        if back[j] != data[j]:
            assert_true(False, "byte " + String(j) + " decoded wrong")


def test_the_encoder_keeps_to_its_window() raises:
    """A stream several windows long decodes under a decoder held to the
    default window; the same stream from a wider window is refused by it,
    so the check can fail."""
    var narrow = ZstdCompressor()
    var held = ZstdDecompressor(window_log_max=DEFAULT_WINDOW_LOG)
    for i in range(8):
        var block = _noise(16384, UInt64(i + 1))
        var back = held.push(Span(narrow.push(Span(block))))
        assert_equal(len(back), len(block))

    var wide = ZstdCompressor(window_log=DEFAULT_WINDOW_LOG + 2)
    var strict = ZstdDecompressor(window_log_max=DEFAULT_WINDOW_LOG)
    var first = _noise(16384, 99)
    var refused = False
    try:
        _ = strict.push(Span(wide.push(Span(first))))
    except e:
        refused = True
    assert_true(refused, "a frame declaring a wider window was decoded")


def test_a_context_stays_under_its_memory_bound() raises:
    """About 200 KB at the defaults (the note's measurement); the bound is
    loose so a libzstd release does not fail it, and tight enough that a
    default moved to a wide window or a high level would."""
    var c = ZstdCompressor()
    for i in range(64):
        _ = c.push(Span(_noise(16384, UInt64(i + 7))))
    var held = c.memory()
    assert_true(held > 0)
    assert_true(held < 512 * 1024, "context holds " + String(held) + " bytes")


def test_a_push_after_the_end_is_refused() raises:
    var c = ZstdCompressor()
    var a = List[UInt8](String("x").as_bytes())
    _ = c.push(Span(a), end=True)
    var refused = False
    try:
        _ = c.push(Span(a))
    except e:
        refused = True
        assert_true("after the frame was ended" in String(e))
    assert_true(refused)


def test_a_window_the_library_refuses_is_an_error() raises:
    var refused = False
    try:
        _ = ZstdCompressor(window_log=40)
    except e:
        refused = True
        assert_true("window log 40" in String(e), String(e))
    assert_true(refused)


def test_a_library_that_is_not_libzstd_is_named() raises:
    var libz: String
    comptime if CompilationTarget.is_macos():
        libz = "libz.1.dylib"
    else:
        libz = "libz.so.1"
    var paths = List[String]()
    paths.append(libz)
    var refused = False
    try:
        _ = open_zstd(paths)
    except e:
        refused = True
        var why = String(e)
        assert_true(libz in why, why)
        assert_true("has no symbol `ZSTD_" in why, why)
    assert_true(refused)


def test_absent_paths_are_each_named() raises:
    var paths = List[String]()
    paths.append("/nonexistent/m0-a/libzstd.so.1")
    paths.append("/nonexistent/m0-b/libzstd.so.1")
    var refused = False
    try:
        _ = open_zstd(paths)
    except e:
        refused = True
        var why = String(e)
        assert_true("M0_LIBZSTD" in why, why)
        assert_true("/nonexistent/m0-a/libzstd.so.1" in why, why)
        assert_true("/nonexistent/m0-b/libzstd.so.1" in why, why)
    assert_true(refused)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
