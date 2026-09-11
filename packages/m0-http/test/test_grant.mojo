"""The grant verifier against grants the Python issuer produced.

Every grant here was issued by `apps/django_realtime/grant.py` (the wheel's
`m0serve.grant`, byte-identical) with a fixed key and clock, so this is the
cross-language agreement test: what Django signs, the mount admits, and
nothing else. Each refusal names its reason, in the order the verifier
refuses.
"""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from src.grant import (
    GrantKeys, verify_grant, grant_key_id, session_binding, base64url,
)

comptime KEY = "test-key-0123456789abcdef0123456789abcdef"
comptime PREV = "previous-key-fedcba9876543210fedcba98765432"
comptime NOW = 1800000000
comptime OK = "v1.6a41f8cf.1800000600.news.ungWv48Bz-pBQUDeXa4iIw.hnaLpdsfR7frsJ1FsmGJ9oCivG0p5SgTr750iyCswpM"
comptime UNBOUND = "v1.6a41f8cf.1800000600.news.-.Pvw91j4fNsFENJQAsdDmT9cwFNRLi9FUINLgC7mzEH0"
comptime EXPIRED = "v1.6a41f8cf.1799999999.news.ungWv48Bz-pBQUDeXa4iIw.j0pn4AhYG3_BAyS5xf2Odcq6iXpKULSv7S0eFzOX7tY"
comptime PREV_SIGNED = "v1.45867b91.1800000600.notate_submission_7.ungWv48Bz-pBQUDeXa4iIw.Yy2N2KP-xpM6OqUH4risFVYIMPXOwasjhqFSgN3HCV4"
comptime TAMPERED = "v1.6a41f8cf.1800000600.news.ungWv48Bz-pBQUDeXa4iIw.hnaLpdsfR7frsJ1FsmGJ9oCivG0p5SgTr750iyCswpA"
comptime TAG = "hnaLpdsfR7frsJ1FsmGJ9oCivG0p5SgTr750iyCswpA"
"""The tampered grant's tag: 43 base64url characters, well formed and wrong."""


def _keys(with_prev: Bool = False) -> GrantKeys:
    var k = GrantKeys()
    k.add(Span(String(KEY).as_bytes()))
    if with_prev:
        k.add(Span(String(PREV).as_bytes()))
    return k^


def _verify(g: String, keys: GrantKeys, now: Int64, cookie: Optional[String]) -> Tuple[Bool, String, String]:
    var v = verify_grant(Span(g.as_bytes()), keys, now, cookie)
    return (v.ok, v.channel, v.reason)


def test_a_grant_the_issuer_signed_admits_its_session() raises:
    """The bound grant, with the cookie it was bound to: admitted, on its
    channel. What the mount does with that is `smoke-hold-mount`'s.

    covers: I21
    """
    var r = _verify(String(OK), _keys(), Int64(NOW), Optional[String](String("abc")))
    assert_true(r[0], r[2])
    assert_equal(r[1], "news")


def test_key_id_and_session_binding_agree_with_the_issuer() raises:
    """`kid` and `sb` are computed on both sides; these are the issuer's."""
    assert_equal(grant_key_id(Span(String(KEY).as_bytes())), "6a41f8cf")
    assert_equal(grant_key_id(Span(String(PREV).as_bytes())), "45867b91")
    assert_equal(session_binding(Span(String("abc").as_bytes())), "ungWv48Bz-pBQUDeXa4iIw")
    var raw = List[UInt8]()
    raw.append(UInt8(0xFB))
    raw.append(UInt8(0xFF))
    assert_equal(base64url(Span(raw)), "-_8")


def test_the_session_binding_is_enforced() raises:
    """No cookie, or another session's cookie: refused, naming which."""
    var none = _verify(String(OK), _keys(), Int64(NOW), None)
    assert_false(none[0])
    assert_equal(none[2], "no session cookie")
    var other = _verify(String(OK), _keys(), Int64(NOW), Optional[String](String("abd")))
    assert_false(other[0])
    assert_equal(other[2], "session mismatch")


def test_an_unbound_grant_needs_no_cookie() raises:
    var r = _verify(String(UNBOUND), _keys(), Int64(NOW), None)
    assert_true(r[0], r[2])
    assert_equal(r[1], "news")


def test_expiry_is_against_the_clock_it_is_given() raises:
    """Expired by the issuer's clock; and the valid grant expires at its
    `exp` exactly, since `now >= exp` refuses."""
    var r = _verify(String(EXPIRED), _keys(), Int64(NOW), Optional[String](String("abc")))
    assert_false(r[0])
    assert_equal(r[2], "expired")
    var late = _verify(String(OK), _keys(), Int64(NOW + 600), Optional[String](String("abc")))
    assert_false(late[0])
    assert_equal(late[2], "expired")
    var just = _verify(String(OK), _keys(), Int64(NOW + 599), Optional[String](String("abc")))
    assert_true(just[0], just[2])


def test_a_tampered_signature_is_refused_before_anything_else_is_read() raises:
    """One character of the tag changed: `bad signature`, even though the
    grant is otherwise valid and in date."""
    var r = _verify(String(TAMPERED), _keys(), Int64(NOW), Optional[String](String("abc")))
    assert_false(r[0])
    assert_equal(r[2], "bad signature")


def test_a_rotated_key_is_accepted_while_it_is_listed() raises:
    """Signed under the previous key: admitted while that key is loaded,
    `unknown key` once it is not -- the rotation window is the key list."""
    var both = _verify(String(PREV_SIGNED), _keys(True), Int64(NOW), Optional[String](String("abc")))
    assert_true(both[0], both[2])
    assert_equal(both[1], "notate_submission_7")
    var only = _verify(String(PREV_SIGNED), _keys(False), Int64(NOW), Optional[String](String("abc")))
    assert_false(only[0])
    assert_equal(only[2], "unknown key")


def test_malformed_grants_are_refused_as_such() raises:
    """Wrong field count, a bad channel byte, a short tag, a non-numeric
    expiry, an unknown version: each `malformed`, none reaching the key."""
    var cookie = Optional[String](String("abc"))
    var cases = List[String]()
    cases.append(String(""))
    cases.append(String("v1.abcdefgh.1800000600.news.-"))
    cases.append(String("v1.abcdefgh.1800000600.ne/ws.-.") + String(TAG))
    cases.append(String("v1.abcdefgh.1800000600.news.-.short"))
    cases.append(String("v1.abcdefgh.18x0000600.news.-.") + String(TAG))
    cases.append(String("v2.abcdefgh.1800000600.news.-.") + String(TAG))
    cases.append(String("v1.abcdefgh.1800000600.news.-.") + String(TAG) + ".extra")
    for i in range(len(cases)):
        var r = _verify(cases[i], _keys(), Int64(NOW), cookie)
        assert_false(r[0], "case " + String(i) + " admitted")
        assert_equal(r[2], "malformed", "case " + String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
