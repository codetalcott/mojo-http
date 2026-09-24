"""Shapes to the wire: one full-state `datastar-patch-signals` frame per step.

Every frame carries every slot, and never a delta. A viewer whose 64 KB
outbox overflows misses frames (`MAX_PENDING_BYTES`); a missed full frame
is healed by the next one, a missed delta would leave a stale blob on that
screen forever.

The signals are underscore-named on purpose. A Datastar fetch action posts
every signal the page holds except those whose name starts with `_`, so
`_b0`..`_b15` never ride a click back to the server; the page's click
action filters to `x` and `y` as well.

Built on the producer thread, so this imports only `m0_datastar.sse` —
the wire format, which depends on nothing — and the bus limit.
"""

from lightbug_http.broadcast import BUS_MAX_FRAME

from m0_datastar.sse import patch_signals

from blobs.kernel import NVERT, SLOTS, Shapes
from blobs.world import STAGE


def _tenths(v: Float32) -> Int:
    """A grid coordinate as tenths of a percent of the stage, clamped to 0–1000."""
    var t = Int(Float64(v) / STAGE * 1000.0 + 0.5)
    if t < 0:
        return 0
    if t > 1000:
        return 1000
    return t


def _pct(v: Float32, mut s: String):
    var t = _tenths(v)
    s += String(t // 10)
    s += "."
    s += String(t % 10)
    s += "%"


def polygon(shapes: Shapes, slot: Int) -> String:
    """`polygon(x% y%,...)` for one filled slot, one decimal place."""
    var s = String("polygon(")
    for v in range(NVERT):
        if v > 0:
            s += ","
        _pct(shapes.px[slot * NVERT + v], s)
        s += " "
        _pct(shapes.py[slot * NVERT + v], s)
    s += ")"
    return s^


def signals_json(
    shapes: Shapes, step_us: Int, viewers: Int, blobs: Int, period_ms: Int
) -> String:
    """The signal object: every slot (empty string when unfilled) and the readouts."""
    var s = String("{")
    for k in range(SLOTS):
        s += '"_b'
        s += String(k)
        s += '":"'
        if shapes.filled[k]:
            s += polygon(shapes, k)
        s += '",'
    s += '"_step_us":'
    s += String(step_us)
    s += ',"_viewers":'
    s += String(viewers)
    s += ',"_blobs":'
    s += String(blobs)
    s += ',"_period_ms":'
    s += String(period_ms)
    s += "}"
    return s^


def state_frame(
    shapes: Shapes,
    step_id: Int,
    step_us: Int,
    viewers: Int,
    blobs: Int,
    period_ms: Int,
) raises -> String:
    """The whole SSE frame for one step, its id the step number."""
    return patch_signals(
        signals=signals_json(shapes, step_us, viewers, blobs, period_ms),
        event_id=String(step_id),
    )


def fits_the_bus(frame: String) -> Bool:
    """Whether the bus will carry `frame` at all (it refuses larger ones)."""
    return frame.byte_length() <= BUS_MAX_FRAME
