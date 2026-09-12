"""LISTEN and NOTIFY: the second door onto the broadcast bus.

Needs a server. `NOTIFY` is what lets a writer that is not inside the
m0serve process tree reach a held SSE stream — a trigger, a cron job,
`psql` — which the datagram bus, by construction, cannot.

The test that matters most is the reset one: a reconnected connection is a
NEW backend session listening to nothing, so a listener that does not
re-`LISTEN` after a reset runs forever delivering nothing and logging no
error. That failure is indistinguishable from nobody publishing, which is
why it is asserted here rather than trusted.
"""

from std.os import getenv
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)

from src import Connection, Params, open


def _url() -> String:
    return getenv("M0_PG_TEST_URL", "postgres:///postgres")


def _drain(mut db: Connection) raises -> List[String]:
    """Every notification waiting, as `channel|payload` strings."""
    var out = List[String]()
    while True:
        var note = db.notifies()
        if not note:
            return out^
        out.append(note.value().channel + "|" + note.value().payload)


def test_a_notification_arrives_with_its_channel_and_payload() raises:
    """The round trip a listener depends on.

    covers: O15
    """
    var db = open(_url())
    db.listen("m0_test_channel")
    db.execute("NOTIFY m0_test_channel, 'hello'")
    var got = _drain(db)
    assert_equal(len(got), 1)
    assert_equal(got[0], "m0_test_channel|hello")
    db.unlisten("m0_test_channel")


def test_the_notifying_backend_names_itself() raises:
    """A self-notification carries this connection's own pid.

    Which is how a listener could ignore its own writes if it ever needed
    to — and how it can tell a publish from elsewhere.

    covers: O15
    """
    var db = open(_url())
    db.listen("m0_test_pid")
    db.execute("NOTIFY m0_test_pid, 'x'")
    var note = db.notifies()
    assert_true(Bool(note))
    assert_equal(note.value().backend_pid, db.backend_pid())
    db.unlisten("m0_test_pid")


def test_a_payload_can_carry_json_and_survives_byte_for_byte() raises:
    """The envelope the listener will carry is JSON, quotes and all.

    `data` is a JSON STRING holding serialized JSON, escapes included,
    because that is the listener's contract: a `data` that is an object is
    refused (`m0-wsgi`'s `pg_envelope.mojo`). This test used to carry
    `"data":{"n":1}`, the very shape the listener delivered as an empty
    event.

    covers: O15
    """
    var envelope = String('{"channel":"room:1","event":"m0","data":"{\\"n\\":1}"}')
    var db = open(_url())
    db.listen("m0_test_json")
    var p = Params()
    p.text(envelope)
    _ = db.query("SELECT pg_notify('m0_test_json', $1)", p)
    var note = db.notifies()
    assert_true(Bool(note))
    assert_equal(note.value().payload, envelope)
    db.unlisten("m0_test_json")


def test_nothing_is_delivered_before_it_is_sent() raises:
    """The null case: an empty drain is what "no news" looks like.

    Without this, a test that only ever asserts delivery passes against a
    `notifies` that returns a stale notification forever.

    covers: O15
    """
    var db = open(_url())
    db.listen("m0_test_quiet")
    assert_equal(len(_drain(db)), 0)
    db.execute("NOTIFY m0_test_quiet, 'once'")
    assert_equal(len(_drain(db)), 1)
    # And the same notification is not delivered twice.
    assert_equal(len(_drain(db)), 0)
    db.unlisten("m0_test_quiet")


def test_a_channel_not_listened_to_is_not_delivered() raises:
    """A subscription is to one channel, not to the server.

    covers: O15
    """
    var db = open(_url())
    db.listen("m0_test_mine")
    db.execute("NOTIFY m0_test_not_mine, 'x'")
    assert_equal(len(_drain(db)), 0)
    db.unlisten("m0_test_mine")


def test_a_reset_restores_every_subscription() raises:
    """The failure that is invisible: a reconnected listener hears nothing.

    `PQreset` opens a new backend session, which is listening to nothing.
    A listener that reconnects without re-`LISTEN`ing runs forever
    delivering no notifications and logging no error, which looks exactly
    like nobody publishing.

    covers: O15
    """
    var db = open(_url())
    db.listen("m0_test_reset")
    var before = db.backend_pid()
    db.reset()
    var after = db.backend_pid()
    # A real reconnection, not a no-op: a new backend has a new pid.
    assert_true(before != after)
    assert_true(db.healthy())
    db.execute("NOTIFY m0_test_reset, 'after the reset'")
    var got = _drain(db)
    assert_equal(len(got), 1)
    assert_equal(got[0], "m0_test_reset|after the reset")
    db.unlisten("m0_test_reset")


def test_a_channel_name_is_quoted_by_the_server() raises:
    """`LISTEN` takes no parameters, so the name goes in as SQL text.

    A channel name is frequently application input, which is why it is
    quoted by libpq against the connection's own encoding rather than by
    doubling quotes here.

    covers: O15
    """
    var db = open(_url())
    db.listen('weird "name" here')
    db.execute("""NOTIFY "weird ""name"" here", 'quoted'""")
    var got = _drain(db)
    assert_equal(len(got), 1)
    assert_equal(got[0], 'weird "name" here|quoted')
    db.unlisten('weird "name" here')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
