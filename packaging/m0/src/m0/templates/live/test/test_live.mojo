"""The wave, the frame and the shared page — everything but the socket.

`uv run m0 test` runs this in two or three seconds: no link, no server.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from m0_http.multiworker import SharedAtomics

from board import B_KICKS, Board, board_slots
from pages import BARS, render_live, render_page, state_frame
from wave import Wave


def test_two_steps_are_two_different_states() raises:
    var w = Wave()
    w.advance(0)
    var first = w.heights()
    w.advance(0)
    var second = w.heights()
    assert_equal(len(first), BARS)
    var moved = False
    for i in range(BARS):
        if first[i] != second[i]:
            moved = True
    assert_true(moved)


def test_a_kick_lifts_the_bars_and_decays() raises:
    var w = Wave()
    w.advance(1)
    var kicked = w.energy
    assert_true(kicked > 0)
    w.advance(0)
    assert_true(w.energy < kicked)
    for _ in range(50):
        w.advance(3)
    for h in w.heights():
        assert_true(h <= 110)


def test_the_frame_is_the_fragment_under_its_own_id() raises:
    """One renderer, two transports: the frame's elements ARE the fragment
    the document paints first, so Datastar morphs it by id."""
    var w = Wave()
    w.advance(0)
    var html = render_live(w.step_no, w.heights(), 2)
    assert_true(html.startswith('<section id="live"'))
    var frame = state_frame(7, w.step_no, w.heights(), 2)
    assert_true(frame.startswith("event: datastar-patch-elements\n"))
    assert_true("id: 7\n" in frame)
    assert_true(String("data: elements ", html) in frame)


def test_a_height_is_clamped_where_it_becomes_css() raises:
    var html = render_live(1, [-5, 250], 0)
    assert_true("height:0%" in html)
    assert_true("height:100%" in html)
    assert_false("250" in html)


def test_the_document_opens_the_stream() raises:
    var page = render_page()
    assert_true(page.startswith("<!doctype html>"))
    # `attr` escaped the quotes for the HTML context; a browser undoes it.
    assert_true("data-init=\"@get(&#x27;/events&#x27;" in page)


def test_viewers_sum_across_workers() raises:
    var shm = SharedAtomics(board_slots(2))
    var board = Board(shm.addr(0))
    board.set_viewers(0, 2)
    board.set_viewers(1, 3)
    assert_equal(board.viewers(2), 5)
    board.add(B_KICKS, 1)
    assert_equal(board.load(B_KICKS), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
