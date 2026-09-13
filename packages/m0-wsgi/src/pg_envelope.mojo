"""The `--pg-listen` payload: three JSON string fields, or a refusal.

A module of its own, apart from `pg_listen.mojo`, so the rule can be tested
as a pure function: this imports neither libpq's binding nor a thread, and
`test_pg_envelope.mojo` runs in `test-wsgi` on every leg with no server.

    {"channel": "room:1", "event": "msg", "data": "hi"}

**Every field present must be a JSON string, and a payload that breaks that
is refused rather than delivered as something else.** `channel` is
required and non-empty; `event` and `data` may be absent, which reads as
the empty string. What is NOT allowed is a present field of another type.
`parse_json_field` answers `""` for an object, a number, an array, `null`
and a malformed escape alike, so `json_build_object('channel', 'x',
'data', row_to_json(NEW))` — the obvious trigger to write — reached every
subscriber as a bare `data: ` and was counted as delivered. An application
that wants structured data serializes it into the string itself
(`row_to_json(NEW)::text`), which is what `m0pub.publish` already receives.
"""

from lightbug_http.broadcast import channel_is_reserved
from m0_core.json_parse import has_json_field, parse_json_string


struct NotifyEnvelope(Copyable, Movable):
    """A payload that passed: where it goes, its event type, its data."""

    var channel: String
    var event: String
    var data: String

    def __init__(out self, var channel: String, var event: String, var data: String):
        self.channel = channel^
        self.event = event^
        self.data = data^


def _optional_string(payload: String, field: String) -> Optional[String]:
    """An absent field as `""`; a present one only if it is a JSON string.

    The outer None is the refusal — a field present with another type.
    """
    if not has_json_field(payload, field):
        return String("")
    return parse_json_string(payload, field)


def parse_notify_payload(payload: String) -> Optional[NotifyEnvelope]:
    """The envelope, or None if the payload is refused.

    Refused: not a JSON object, no `channel` or an empty or non-string one,
    a reserved channel (`\\x01…`, defence in depth — `publish_to_channels`
    refuses the same names at the bus boundary), and an `event` or `data`
    that is present but not a string.
    """
    var channel = parse_json_string(payload, "channel")
    if not channel:
        return None
    if len(channel.value().as_bytes()) == 0:
        return None
    if channel_is_reserved(channel.value()):
        # The control namespace addresses connection slots on the loop. A
        # name from the database is as untrusted as one from a form body.
        return None
    var event = _optional_string(payload, "event")
    if not event:
        return None
    var data = _optional_string(payload, "data")
    if not data:
        return None
    return NotifyEnvelope(channel.value(), event.value(), data.value())
