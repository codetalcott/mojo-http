"""One assertion per rule, through the table the server serves.

`uv run m0 test` runs this in two or three seconds: no link, no socket, no
server. Put logic where a test like these can reach it.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.header import Header, Headers, HeaderKey
from lightbug_http.http import HTTPRequest, HTTPResponse
from lightbug_http.io.bytes import Bytes
from lightbug_http.uri import URI

from pages import EVENTS, render_board, render_compose, render_page
from views import MAX_MESSAGES, Board, board_urls


def _post(
    body: String, content_type: String = "application/x-www-form-urlencoded"
) raises -> HTTPRequest:
    return HTTPRequest(
        URI.parse("http://127.0.0.1/messages"),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, content_type)),
        method="POST",
        body=Bytes(body.as_bytes()),
    )


def _body(resp: HTTPResponse) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(resp.body_raw)))


def _bytes(b: List[UInt8]) -> String:
    return String(StringSpan(unsafe_from_utf8=Span(b)))


def test_a_post_adds_the_message_and_empties_the_input() raises:
    var board = Board(16)
    var table = board_urls()
    var resp = table.dispatch(_post("text=hello+there"), board)
    assert_equal(resp.status_code, 200)
    assert_equal(_body(resp), '{"text":""}')
    assert_equal(len(board.messages), 1)
    assert_equal(board.messages[0], "hello there")


def test_a_post_sends_the_board_to_every_open_stream() raises:
    """The view is the sender: two subscribed slots each get one frame
    whose elements are the board with the message in it."""
    var board = Board(16)
    var table = board_urls()
    for slot in [3, 7]:
        var get = HTTPRequest(URI.parse(String("http://127.0.0.1", EVENTS)))
        get.slot_id = slot
        _ = table.dispatch(get, board)
    _ = table.dispatch(_post("text=hi"), board)
    for slot in [3, 7]:
        var sent = _bytes(board.stream.drain(slot))
        assert_true("event: datastar-patch-elements" in sent)
        assert_true('<section id="board"><ul><li>hi</li></ul></section>' in sent)


def test_an_empty_or_missing_message_is_refused_as_problem_json() raises:
    var board = Board(16)
    var table = board_urls()
    var empty = table.dispatch(_post("text="), board)
    assert_equal(empty.status_code, 422)
    assert_true('"instance":"/messages"' in _body(empty))
    assert_equal(table.dispatch(_post("other=x"), board).status_code, 422)
    var not_form = table.dispatch(_post('{"text":"x"}', "application/json"), board)
    assert_equal(not_form.status_code, 400)
    assert_equal(len(board.messages), 0)


def test_the_board_is_newest_first_and_keeps_the_newest_fifty() raises:
    var board = Board(16)
    for i in range(MAX_MESSAGES + 5):
        board.add(String("m", i))
    assert_equal(len(board.messages), MAX_MESSAGES)
    var html = render_board(board.messages)
    assert_true(html.startswith('<section id="board"'))
    var newest = html.find(String(">m", MAX_MESSAGES + 4, "</li>"))
    var older = html.find(String(">m", MAX_MESSAGES + 3, "</li>"))
    assert_true(newest >= 0 and older > newest)
    assert_false(">m4</li>" in html)


def test_a_message_is_escaped_where_it_is_rendered() raises:
    var html = render_board([String("<b>&")])
    assert_true("&lt;b&gt;&amp;" in html)
    assert_false("<b>" in html)


def test_the_form_posts_its_fields_and_the_document_opens_the_stream() raises:
    var compose = render_compose()
    assert_true(compose.startswith('<section id="compose"'))
    # `attr` escaped the quotes for the HTML context; a browser undoes it.
    assert_true("data-on:submit__prevent=" in compose)
    assert_true("contentType: &#x27;form&#x27;" in compose)
    assert_true(" data-bind:text" in compose)
    assert_true(" required" in compose)
    assert_false("</input>" in compose)
    var page = render_page(List[String]())
    assert_true(page.startswith("<!doctype html>"))
    assert_true("data-init=\"@get(&#x27;/events&#x27;" in page)
    assert_true("nothing yet" in page)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
