"""Tests for `Headers`, whose storage is a flat byte blob plus (offset,
length) index arrays rather than a `Dict[String, String]`.

That substitution is invisible through the public API by design, which is
exactly why it needs tests of its own: every existing suite exercises
`Headers` only indirectly, through routing, parsing and the smoke apps, so
none of them would notice the semantics below drifting. Each test here pins
a behaviour the Dict gave for free and the blob has to implement by hand —
case folding, last-value-wins on duplicates, index shifting after a `pop`,
and reading a value without materializing a String.
"""

from lightbug_http.header import Headers, Header, HeaderKey, parse_request_headers
from std.testing import assert_equal, assert_true, assert_false, TestSuite


def value_of(headers: Headers, key: String) raises -> String:
    """Fetch a header's value, failing the test if it is absent.

    `get(key).value()` aborts the process when the key is missing, so a
    broken lookup would surface as an opaque crash with no test name
    attached. Routing every lookup assertion through here turns the same
    regression into a named failure.
    """
    var found = headers.get(key)
    assert_true(Bool(found), String("expected header to be present: ", key))
    return found.value()


# --- Lookup and case folding ------------------------------------------------


def test_lookup_is_case_insensitive() raises:
    """A probe in any case finds a header stored in any other case."""
    var headers = Headers()
    headers["Content-Type"] = "application/json"

    assert_equal(value_of(headers, "content-type"), "application/json")
    assert_equal(value_of(headers, "Content-Type"), "application/json")
    assert_equal(value_of(headers, "CONTENT-TYPE"), "application/json")
    assert_equal(value_of(headers, "CoNtEnT-tYpE"), "application/json")


def test_names_are_stored_lowercased() raises:
    """However a name arrives, it is stored (and enumerated) lowercase.

    The WSGI `environ` projection builds `HTTP_*` keys off `keys()`, so a
    stored name that kept its original case would produce the wrong environ
    key for every mixed-case header a client sends.
    """
    var headers = Headers()
    headers["X-Custom-Header"] = "v"

    var names = headers.keys()
    assert_equal(len(names), 1)
    assert_equal(names[0], "x-custom-header")


def test_contains_is_case_insensitive() raises:
    var headers = Headers()
    headers["Accept"] = "text/html"

    assert_true("accept" in headers)
    assert_true("ACCEPT" in headers)
    assert_false("accept-encoding" in headers)


def test_missing_key_returns_none_and_raises_on_subscript() raises:
    var headers = Headers()
    headers["a"] = "1"

    assert_false(Bool(headers.get("nope")))
    var raised = False
    try:
        _ = headers["nope"]
    except:
        raised = True
    assert_true(raised)


def test_lookup_does_not_match_on_prefix() raises:
    """Length is compared before bytes; a prefix must not match.

    The scan compares lengths first as a fast reject, so this is the test
    that would catch that check being dropped or inverted.
    """
    var headers = Headers()
    headers["content-type"] = "text/plain"

    assert_false("content" in headers)
    assert_false("content-type-extra" in headers)
    assert_true("content-type" in headers)


# --- Insertion, overwrite, duplicates ---------------------------------------


def test_overwrite_replaces_value_and_keeps_one_entry() raises:
    """Setting an existing name overwrites rather than appending.

    The blob strands the old value bytes instead of compacting, so the
    thing to assert is that the *index* still holds a single entry
    pointing at the new value.
    """
    var headers = Headers()
    headers["x"] = "first"
    headers["x"] = "second"

    assert_equal(value_of(headers, "x"), "second")
    assert_equal(headers.count(), 1)
    assert_equal(len(headers.keys()), 1)


def test_overwrite_matches_case_insensitively() raises:
    """A differently-cased name overwrites; it does not create a second entry."""
    var headers = Headers()
    headers["Set-Cookie-Ish"] = "a"
    headers["set-cookie-ish"] = "b"

    assert_equal(headers.count(), 1)
    assert_equal(value_of(headers, "SET-COOKIE-ISH"), "b")


def test_repeated_overwrite_stays_correct() raises:
    """Many overwrites keep resolving to the newest value.

    Each one appends to the blob and repoints the index, so this walks the
    path where stranded bytes accumulate and the offsets must stay right.
    """
    var headers = Headers()
    for i in range(20):
        headers["counter"] = String(i)

    assert_equal(headers.count(), 1)
    assert_equal(value_of(headers, "counter"), "19")


def test_insertion_order_is_preserved() raises:
    """Names enumerate in insertion order — the Dict never promised this."""
    var headers = Headers()
    headers["first"] = "1"
    headers["second"] = "2"
    headers["third"] = "3"

    var names = headers.keys()
    assert_equal(len(names), 3)
    assert_equal(names[0], "first")
    assert_equal(names[1], "second")
    assert_equal(names[2], "third")


def test_overwrite_does_not_move_a_header_in_the_order() raises:
    """Overwriting a value keeps the name where it was first inserted."""
    var headers = Headers()
    headers["a"] = "1"
    headers["b"] = "2"
    headers["a"] = "999"

    var names = headers.keys()
    assert_equal(len(names), 2)
    assert_equal(names[0], "a")
    assert_equal(names[1], "b")
    assert_equal(value_of(headers, "a"), "999")


def test_empty_value_round_trips() raises:
    """A zero-length value is present, distinct from absent."""
    var headers = Headers()
    headers["x-empty"] = ""

    assert_true("x-empty" in headers)
    assert_equal(value_of(headers, "x-empty"), "")


def test_variadic_constructor_populates() raises:
    var headers = Headers(
        Header(HeaderKey.CONTENT_TYPE, "text/html"),
        Header("X-Trace", "abc"),
    )

    assert_equal(headers.count(), 2)
    assert_equal(value_of(headers, "content-type"), "text/html")
    assert_equal(value_of(headers, "x-trace"), "abc")


# --- pop --------------------------------------------------------------------


def test_pop_removes_only_the_named_header() raises:
    """`pop` drops one index entry; the neighbours keep their values.

    Four parallel arrays have to shift in lockstep here — this is the test
    that catches one of them being missed.
    """
    var headers = Headers()
    headers["a"] = "1"
    headers["b"] = "2"
    headers["c"] = "3"

    headers.pop("b")

    assert_equal(headers.count(), 2)
    assert_false("b" in headers)
    assert_equal(value_of(headers, "a"), "1")
    assert_equal(value_of(headers, "c"), "3")


def test_pop_is_case_insensitive_and_absent_is_a_noop() raises:
    var headers = Headers()
    headers["Content-Length"] = "5"

    headers.pop("nonexistent")
    assert_equal(headers.count(), 1)

    headers.pop("CONTENT-LENGTH")
    assert_equal(headers.count(), 0)
    assert_true(headers.empty())


def test_set_after_pop_reuses_the_name_correctly() raises:
    """Re-adding a popped name appends a fresh entry with the new value.

    The popped name's bytes are still in the blob; a lookup must resolve
    through the index, not by scanning those orphaned bytes.
    """
    var headers = Headers()
    headers["a"] = "1"
    headers["b"] = "2"
    headers.pop("a")
    headers["a"] = "reborn"

    assert_equal(headers.count(), 2)
    assert_equal(value_of(headers, "a"), "reborn")
    assert_equal(value_of(headers, "b"), "2")

    var names = headers.keys()
    assert_equal(names[0], "b")
    assert_equal(names[1], "a")


def test_pop_every_header_then_reuse() raises:
    var headers = Headers()
    headers["x"] = "1"
    headers["y"] = "2"
    headers.pop("x")
    headers.pop("y")
    assert_true(headers.empty())

    headers["z"] = "3"
    assert_equal(headers.count(), 1)
    assert_equal(value_of(headers, "z"), "3")


# --- content_length ---------------------------------------------------------


def test_content_length_parses_digits() raises:
    var headers = Headers()
    headers[HeaderKey.CONTENT_LENGTH] = "1234"
    assert_equal(headers.content_length(), 1234)


def test_content_length_absent_is_zero() raises:
    var headers = Headers()
    assert_equal(headers.content_length(), 0)


def test_content_length_rejects_non_numeric() raises:
    """Malformed values read as 0 rather than raising or partially parsing.

    This runs on the request path, where a bad Content-Length must not be
    able to produce a nonsense body length.
    """
    var headers = Headers()

    headers[HeaderKey.CONTENT_LENGTH] = ""
    assert_equal(headers.content_length(), 0)

    headers[HeaderKey.CONTENT_LENGTH] = "12abc"
    assert_equal(headers.content_length(), 0)

    headers[HeaderKey.CONTENT_LENGTH] = "abc"
    assert_equal(headers.content_length(), 0)

    headers[HeaderKey.CONTENT_LENGTH] = "-5"
    assert_equal(headers.content_length(), 0)

    headers[HeaderKey.CONTENT_LENGTH] = "1 2"
    assert_equal(headers.content_length(), 0)


def test_content_length_zero_and_large() raises:
    var headers = Headers()

    headers[HeaderKey.CONTENT_LENGTH] = "0"
    assert_equal(headers.content_length(), 0)

    headers[HeaderKey.CONTENT_LENGTH] = "4194304"
    assert_equal(headers.content_length(), 4194304)


# --- value_equals_ignore_case ------------------------------------------------


def test_value_equals_ignore_case() raises:
    """The allocation-free comparison behind `Connection: close`."""
    var headers = Headers()
    headers[HeaderKey.CONNECTION] = "close"
    assert_true(headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close"))
    assert_true(headers.value_equals_ignore_case(HeaderKey.CONNECTION, "CLOSE"))

    headers[HeaderKey.CONNECTION] = "Close"
    assert_true(headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close"))

    headers[HeaderKey.CONNECTION] = "CLOSE"
    assert_true(headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close"))


def test_value_equals_ignore_case_rejects_mismatches() raises:
    var headers = Headers()
    headers[HeaderKey.CONNECTION] = "keep-alive"

    assert_false(headers.value_equals_ignore_case(HeaderKey.CONNECTION, "close"))
    # Absent header is not a match.
    assert_false(headers.value_equals_ignore_case("x-absent", "close"))
    # A prefix of the value is not a match.
    assert_false(headers.value_equals_ignore_case(HeaderKey.CONNECTION, "keep"))


# --- Round trip through the parser ------------------------------------------


def test_parsed_request_headers_are_queryable() raises:
    """Headers filled by the parser behave like ones set by hand.

    The parser writes through `set_bytes` with slices of the receive
    buffer rather than through `__setitem__`, so it is a second, separate
    path into the same storage.
    """
    var raw = String(
        "GET / HTTP/1.1\r\n",
        "Host: example.com\r\n",
        "Content-Type: application/json\r\n",
        "X-Mixed-Case: Value\r\n",
        "\r\n",
    )
    var parsed = parse_request_headers(raw.as_bytes())

    assert_equal(value_of(parsed.headers, "host"), "example.com")
    assert_equal(value_of(parsed.headers, "HOST"), "example.com")
    assert_equal(value_of(parsed.headers, "content-type"), "application/json")
    # The name folds, the value does not.
    assert_equal(value_of(parsed.headers, "x-mixed-case"), "Value")


def test_parser_trims_surrounding_whitespace_from_values() raises:
    """RFC 9110 §5.5 OWS is trimmed by moving span endpoints, not `.strip()`."""
    var raw = String(
        "GET / HTTP/1.1\r\n",
        "Host: example.com\r\n",
        "X-Padded:    spaced out   \r\n",
        "\r\n",
    )
    var parsed = parse_request_headers(raw.as_bytes())
    assert_equal(value_of(parsed.headers, "x-padded"), "spaced out")


def test_parsed_headers_can_be_overwritten_afterwards() raises:
    """A response path mutating parsed headers must not corrupt the blob.

    This is the mixed path: bytes appended by the parser, then more
    appended by `__setitem__` on the same instance.
    """
    var raw = String(
        "GET / HTTP/1.1\r\n",
        "Host: example.com\r\n",
        "Content-Type: text/plain\r\n",
        "\r\n",
    )
    var parsed = parse_request_headers(raw.as_bytes())
    var headers = parsed.headers.copy()

    headers["Content-Type"] = "application/json"
    headers["X-Added"] = "new"
    headers.pop("host")

    assert_equal(value_of(headers, "content-type"), "application/json")
    assert_equal(value_of(headers, "x-added"), "new")
    assert_false("host" in headers)


def test_duplicate_names_keep_the_last_value() raises:
    """Repeated non-cookie names collapse to the last one seen.

    Matches the `Dict` this replaced, where a second insert overwrote the
    first. (Content-Length is exempt: a duplicate is rejected outright as a
    request-smuggling vector, asserted in test_parsing.mojo.)
    """
    var raw = String(
        "GET / HTTP/1.1\r\n",
        "Host: example.com\r\n",
        "X-Dup: one\r\n",
        "X-Dup: two\r\n",
        "\r\n",
    )
    var parsed = parse_request_headers(raw.as_bytes())

    assert_equal(value_of(parsed.headers, "x-dup"), "two")


# --- Whole-collection behaviour ---------------------------------------------


def test_empty_headers() raises:
    var headers = Headers()
    assert_true(headers.empty())
    assert_equal(headers.count(), 0)
    assert_equal(len(headers.keys()), 0)
    assert_false("anything" in headers)


def test_equality_ignores_insertion_order() raises:
    """Two collections with the same pairs compare equal either way round."""
    var a = Headers()
    a["x"] = "1"
    a["y"] = "2"

    var b = Headers()
    b["y"] = "2"
    b["x"] = "1"

    assert_true(a == b)

    b["z"] = "3"
    assert_false(a == b)


def test_copy_is_independent() raises:
    """A copy owns its own blob; mutating one must not touch the other."""
    var original = Headers()
    original["shared"] = "before"

    var duplicate = original.copy()
    duplicate["shared"] = "after"
    duplicate["only-in-copy"] = "yes"

    assert_equal(value_of(original, "shared"), "before")
    assert_equal(original.count(), 1)
    assert_equal(value_of(duplicate, "shared"), "after")
    assert_equal(duplicate.count(), 2)


def test_many_headers_all_resolve() raises:
    """Lookup is a linear scan; make sure it stays correct at depth.

    The parser admits up to 100 headers, so this covers the far end of the
    range where an offset or length mix-up would surface as a wrong value
    rather than a crash.
    """
    var headers = Headers()
    for i in range(60):
        headers[String("x-header-", i)] = String("value-", i)

    assert_equal(headers.count(), 60)
    for i in range(60):
        assert_equal(value_of(headers, String("X-Header-", i)), String("value-", i))

    assert_false("x-header-60" in headers)


def test_cookie_header_survives_parsing() raises:
    """`Cookie` must stay in `headers`, not only in the jar.

    A WSGI application is handed the raw field and parses cookies itself, so
    diverting it out of `headers` erased `HTTP_COOKIE` from the environ — and
    with it every session, login and CSRF check.
    """
    var raw = String(
        "GET / HTTP/1.1\r\n",
        "Host: example.com\r\n",
        "Cookie: sessionid=abc123; csrftoken=xyz789\r\n",
        "\r\n",
    )
    var parsed = parse_request_headers(raw.as_bytes())

    assert_equal(
        value_of(parsed.headers, "cookie"), "sessionid=abc123; csrftoken=xyz789"
    )


def test_split_cookie_headers_rejoin() raises:
    """Several `Cookie` fields are one "; "-joined list, not a last-wins race.

    `Headers` is a unique-key map, so the join has to happen after the parse
    loop; setting per line would keep only the final field.
    """
    var raw = String(
        "GET / HTTP/1.1\r\n",
        "Host: example.com\r\n",
        "Cookie: a=1\r\n",
        "Cookie: b=2\r\n",
        "\r\n",
    )
    var parsed = parse_request_headers(raw.as_bytes())

    assert_equal(value_of(parsed.headers, "cookie"), "a=1; b=2")


def test_set_cookie_on_a_request_is_an_ordinary_header() raises:
    """`Set-Cookie` is a response field; on a request it is not a cookie.

    It used to be folded into the request's own cookie list, which invented a
    request cookie the client never sent.
    """
    var raw = String(
        "GET / HTTP/1.1\r\n",
        "Host: example.com\r\n",
        "Set-Cookie: injected=1\r\n",
        "\r\n",
    )
    var parsed = parse_request_headers(raw.as_bytes())

    assert_equal(value_of(parsed.headers, "set-cookie"), "injected=1")
    assert_false("cookie" in parsed.headers)
    assert_equal(len(parsed.cookies), 0)


def test_no_cookie_header_leaves_none_behind() raises:
    """A request without cookies must not gain an empty `Cookie` field."""
    var raw = String("GET / HTTP/1.1\r\n", "Host: example.com\r\n", "\r\n")
    var parsed = parse_request_headers(raw.as_bytes())

    assert_false("cookie" in parsed.headers)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
