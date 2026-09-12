"""The session verifier against cookies a CPython issuer signed.

Every constant below was printed by `python3 scripts/notes_session.py
--vectors`, which signs with `hmac` and `hashlib` and knows nothing about
this file. So this is the cross-language agreement test, the shape
`test_grant.mojo` uses: what the other implementation signs, this one
admits, and nothing else. The CSRF token is in the table for the same
reason — a derivation only ever checked against itself can drift without
anyone noticing until a form stops submitting.

Regenerating is a diff, not a transcription: re-run the script and paste.
"""

from std.testing import assert_equal, assert_false, assert_not_equal, assert_true, TestSuite

from src.session import (
    SessionKeys,
    SessionVerdict,
    csrf_token,
    issue_session,
    session_cookie_line,
    verify_session,
)

comptime KEY = "notes-key-0123456789abcdef0123456789abcdef"
comptime PREV = "notes-prev-fedcba9876543210fedcba9876543210"
comptime NOW = 1800000000
comptime KID = "4d2d3960"
comptime OK = "v1.4d2d3960.1800000600.notes.1nhjo_vzwsmxxb_Oj3UMceZX4aaSVIyfpYlVqTr7LhI"
comptime CSRF = "MuYjaJBt1_pCz3Z6w84ZuldquOsbgb_-dQSSITRAVXo"
comptime EXPIRED = "v1.4d2d3960.1799999999.notes.X1QjhBIosY5t_URHbIxG0eB9HMuhEsq7iIppXpHSez0"
comptime PREV_SIGNED = "v1.543627e7.1800000600.notes.nUDjdN8_-uqwibCFzL8KMpCACrvuP8V-XJQ1mXpuhMw"
comptime OTHER_SUBJECT = "v1.4d2d3960.1800000600.someone_else.1E8m-dHMnykYUwSfczqpmVvJoP-pJEvjzWHDNprp44s"
comptime TAMPERED = "v1.4d2d3960.1800000600.notes.1nhjo_vzwsmxxb_Oj3UMceZX4aaSVIyfpYlVqTr7LhA"


def _keys(with_prev: Bool = False) -> SessionKeys:
    var k = SessionKeys()
    k.add(Span(String(KEY).as_bytes()))
    if with_prev:
        k.add(Span(String(PREV).as_bytes()))
    return k^


def _verify(c: String, keys: SessionKeys, now: Int64) -> Tuple[Bool, String, String, String]:
    var v = verify_session(Span(c.as_bytes()), keys, now)
    return (v.ok, v.subject, v.csrf, v.reason)


def test_a_cookie_the_issuer_signed_names_its_subject() raises:
    """The valid vector: admitted, naming the subject it was signed for."""
    var r = _verify(String(OK), _keys(), Int64(NOW))
    assert_true(r[0], r[3])
    assert_equal(r[1], "notes")


def test_the_csrf_token_agrees_with_the_issuer() raises:
    """The derivation, against the other implementation's answer for the
    same cookie. A token both sides compute differently is a form that
    submits once and never again."""
    var r = _verify(String(OK), _keys(), Int64(NOW))
    assert_equal(r[2], CSRF)


def test_the_csrf_token_is_bound_to_its_own_session() raises:
    """Two sessions, two tokens. What makes one session's form useless in
    another's tab — and the reason the token is derived from the tag
    rather than from the key or the subject, which both sessions share."""
    var mine = _verify(String(OK), _keys(), Int64(NOW))
    var theirs = _verify(String(OTHER_SUBJECT), _keys(), Int64(NOW))
    assert_true(mine[0], mine[3])
    assert_true(theirs[0], theirs[3])
    assert_not_equal(mine[2], theirs[2])


def test_the_csrf_token_is_not_the_session_tag() raises:
    """Domain separation: the token is a MAC over a message the cookie's
    signed part can never be, so neither is ever the other."""
    var r = _verify(String(OK), _keys(), Int64(NOW))
    assert_not_equal(r[2], String(String(OK).split(".")[4]))


def test_expiry_is_against_the_clock_it_is_given() raises:
    """Expired by the issuer's clock; and the valid one expires at its own
    second, not after it."""
    var gone = _verify(String(EXPIRED), _keys(), Int64(NOW))
    assert_false(gone[0])
    assert_equal(gone[3], "expired")
    var edge = _verify(String(OK), _keys(), Int64(1800000600))
    assert_false(edge[0])
    assert_equal(edge[3], "expired")
    var just = _verify(String(OK), _keys(), Int64(1800000599))
    assert_true(just[0], just[3])


def test_a_tampered_tag_is_refused_before_the_expiry_is_read() raises:
    """One character of the tag changed: `bad signature`, on a cookie that
    is otherwise valid and in date. An expired cookie nobody signed must
    not come back as merely expired."""
    var r = _verify(String(TAMPERED), _keys(), Int64(NOW))
    assert_false(r[0])
    assert_equal(r[3], "bad signature")


def test_a_key_the_ring_does_not_hold_is_unknown_not_invalid() raises:
    """Signed under the previous key: admitted while that key is listed,
    `unknown key` once it is not. Dropping a key is what ends every
    session under it, and this is that mechanism."""
    var both = _verify(String(PREV_SIGNED), _keys(True), Int64(NOW))
    assert_true(both[0], both[3])
    assert_equal(both[1], "notes")
    var only = _verify(String(PREV_SIGNED), _keys(False), Int64(NOW))
    assert_false(only[0])
    assert_equal(only[3], "unknown key")


def test_an_empty_ring_refuses_everything() raises:
    """A server that lost its keys admits nothing, rather than admitting
    anything."""
    var r = _verify(String(OK), SessionKeys(), Int64(NOW))
    assert_false(r[0])
    assert_equal(r[3], "unknown key")


def test_malformed_cookies_are_refused_as_such() raises:
    """Wrong field count, a bad subject byte, a short tag, a non-numeric
    expiry, an unknown version, a trailing field: each `malformed`, none
    reaching the key."""
    var cases = List[String]()
    cases.append(String(""))
    cases.append(String("not-a-session-cookie-at-all"))
    cases.append(String("v1.4d2d3960.1800000600.notes"))
    cases.append(String("v1.4d2d3960.1800000600.no tes.") + String(CSRF))
    cases.append(String("v1.4d2d3960.1800000600.notes.short"))
    cases.append(String("v1.4d2d3960.18x0000600.notes.") + String(CSRF))
    cases.append(String("v2.4d2d3960.1800000600.notes.") + String(CSRF))
    cases.append(String("v1.4d2d396.1800000600.notes.") + String(CSRF))
    cases.append(String(OK) + ".extra")
    for i in range(len(cases)):
        var r = _verify(cases[i], _keys(), Int64(NOW))
        assert_false(r[0], "case " + String(i) + " admitted")
        assert_equal(r[3], "malformed", "case " + String(i))


def test_a_cookie_holding_bytes_that_are_not_utf8_is_refused_not_fatal() raises:
    """A cookie is request-derived, so its fields are walked as bytes: a
    continuation byte in the subject is `malformed`, and the codepoint
    slice that would have trapped on it is not there to trap (SPEC G14)."""
    var raw = List[UInt8]()
    raw.extend(String("v1.4d2d3960.1800000600.no").as_bytes())
    raw.append(UInt8(0x80))
    raw.extend(String("tes.").as_bytes())
    raw.extend(String(CSRF).as_bytes())
    var v = verify_session(Span(raw), _keys(), Int64(NOW))
    assert_false(v.ok)
    assert_equal(v.reason, "malformed")


def test_what_this_server_issues_this_server_reads() raises:
    """The round trip, and the property the wire gate cannot see: the
    cookie the app sets is one its own verifier admits, with the CSRF
    token the form will carry."""
    var keys = _keys()
    var value = issue_session(keys, String("notes"), Int64(NOW + 600))
    assert_equal(value, OK)
    var v = verify_session(Span(value.as_bytes()), keys, Int64(NOW))
    assert_true(v.ok, v.reason)
    assert_equal(v.subject, "notes")
    assert_equal(v.csrf, CSRF)


def test_a_subject_the_format_cannot_carry_is_refused_at_issue() raises:
    """Not at verification, which would be a session nobody can use and a
    reason nobody can act on. A `.` would add a field, an empty subject
    would make the cookie ambiguous, and 65 bytes exceeds what the
    verifier accepts."""
    var keys = _keys()
    var refused = 0
    for bad in [String(""), String("a.b"), String("a b"), String("a;b")]:
        try:
            _ = issue_session(keys, bad, Int64(NOW + 600))
        except:
            refused += 1
    assert_equal(refused, 4)
    var long = String("")
    for _ in range(65):
        long += "a"
    var caught = False
    try:
        _ = issue_session(keys, long, Int64(NOW + 600))
    except:
        caught = True
    assert_true(caught, "a 65-byte subject was issued")


def test_issuing_without_a_key_raises_rather_than_signing_with_nothing() raises:
    var caught = False
    try:
        _ = issue_session(SessionKeys(), String("notes"), Int64(NOW + 600))
    except:
        caught = True
    assert_true(caught, "an empty ring issued a cookie")


def test_the_cookie_line_carries_the_attributes_that_are_the_defence() raises:
    """`HttpOnly` keeps it from scripts, `SameSite=Lax` keeps it off every
    cross-site write, `Path=/` scopes it, `Max-Age=0` ends it. Built as a
    line for `add_raw`, because the parsed path drops three of the four."""
    var line = session_cookie_line(String("sid"), String(OK), Int64(3600))
    assert_equal(
        line,
        String("sid=", OK, "; Path=/; HttpOnly; SameSite=Lax; Max-Age=3600"),
    )
    assert_equal(
        session_cookie_line(String("sid"), String(""), Int64(0)),
        "sid=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
    )
    assert_equal(
        session_cookie_line(String("sid"), String("x"), Int64(1), True),
        "sid=x; Path=/; HttpOnly; SameSite=Lax; Max-Age=1; Secure",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
