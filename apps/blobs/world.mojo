"""The blobs world: where every blob is, and how it moves.

This is the state the producer thread owns and nothing else touches. It
knows nothing about contours or the wire: `Tracer.trace` turns it into
shapes, `wire.state_frame` turns those into a frame. A blob carries a field
STRENGTH rather than a radius: the metaball field is `strength / (d^2 + 1)`,
and a lone blob's contour at `ISO = 1` sits at `d = sqrt(strength - 1)`.

Coordinates are grid units on a `STAGE x STAGE` square, the kernel's
sampling grid, with y increasing downward as on the page.

Blob `i` is drawn in slot `i` for its whole life, so a slot never jumps
across the stage. A drop takes the slot after the last one taken and
evicts whatever was there — oldest first, which is what bounds a step's
work whatever visitors do.
"""

from std.math import sqrt

comptime STAGE = Float64(192.0)
"""Side of the square stage, in grid units: the kernel's grid."""

comptime MAX_BLOBS = 16
"""Most blobs alive at once. A drop past this evicts the oldest."""

comptime SEED_BLOBS = 5
"""Blobs the world starts with, so a first visitor sees something move."""

comptime MIN_STRENGTH = Float64(90.0)
comptime MAX_STRENGTH = Float64(130.0)

comptime EDGE_GAP = Float64(12.0)
"""Grid units kept clear between a lone blob's contour and the stage edge."""

comptime SPEED = Float64(18.0)
"""Grid units per second, before the per-blob jitter."""


def contour_radius(strength: Float64) -> Float64:
    """Where a lone blob's field falls to 1: `strength / (d^2 + 1) = 1`."""
    return sqrt(strength - 1.0)


def keep_out() -> Float64:
    """How close a blob's CENTRE may come to any edge.

    A lone blob stays a contour radius plus a gap inside the stage, so it is
    never drawn flattened against a wall. This is a look, not a safety
    rule: the kernel's zero border closes every contour whatever the
    centres do, and merged blobs do reach a wall — sixteen at one point
    reach ~45 grid units, twice this. The drop view clamps to it, and
    motion bounces off it.
    """
    return contour_radius(MAX_STRENGTH) + EDGE_GAP


def clamp_centre(v: Float64) -> Float64:
    """`v`, moved inside the band a centre may occupy."""
    var lo = keep_out()
    var hi = STAGE - lo
    if not (v >= lo):  # also catches NaN
        return lo
    if v > hi:
        return hi
    return v


struct World(Movable):
    """Up to `MAX_BLOBS` blobs, as parallel lists (the repo's SoA habit)."""

    var x: List[Float64]
    var y: List[Float64]
    var vx: List[Float64]
    var vy: List[Float64]
    var strength: List[Float64]
    var alive: List[Bool]
    var next: Int
    """The slot the next drop takes."""
    var _rng: UInt64

    def __init__(out self, seed: UInt64 = 0x9E3779B97F4A7C15):
        self.x = List[Float64](length=MAX_BLOBS, fill=0.0)
        self.y = List[Float64](length=MAX_BLOBS, fill=0.0)
        self.vx = List[Float64](length=MAX_BLOBS, fill=0.0)
        self.vy = List[Float64](length=MAX_BLOBS, fill=0.0)
        self.strength = List[Float64](length=MAX_BLOBS, fill=0.0)
        self.alive = List[Bool](length=MAX_BLOBS, fill=False)
        self.next = 0
        self._rng = seed if seed != 0 else 1
        var lo = keep_out()
        var span = STAGE - 2.0 * lo
        for _ in range(SEED_BLOBS):
            self.drop(lo + self._unit() * span, lo + self._unit() * span)

    def _unit(mut self) -> Float64:
        """xorshift64: deterministic, and no global state for a thread to share."""
        var r = self._rng
        r ^= r << 13
        r ^= r >> 7
        r ^= r << 17
        self._rng = r
        return Float64(r >> 11) / Float64(UInt64(1) << 53)

    def count(self) -> Int:
        var n = 0
        for i in range(MAX_BLOBS):
            if self.alive[i]:
                n += 1
        return n

    def drop(mut self, gx: Float64, gy: Float64):
        """Place a blob at (`gx`, `gy`), clamped, evicting the oldest if full.

        The clamp here is one of three layers: `advance` clamps too, and its
        bounce reflects an out-of-band centre inside. The producer advances
        before it traces, so on the wire the other two would hide this one's
        absence; a world traced before it is advanced (the kernel tests)
        needs it.
        """
        var i = self.next
        self.next = (self.next + 1) % MAX_BLOBS
        self.x[i] = clamp_centre(gx)
        self.y[i] = clamp_centre(gy)
        var speed = SPEED * (0.5 + self._unit())
        # A unit vector without trig, so this file needs only sqrt.
        var ux = 1.0 - 2.0 * self._unit()
        var uy = 1.0 - 2.0 * self._unit()
        var n = sqrt(ux * ux + uy * uy)
        if n < 1e-6:
            ux = 1.0
            uy = 0.0
            n = 1.0
        self.vx[i] = speed * ux / n
        self.vy[i] = speed * uy / n
        self.strength[i] = MIN_STRENGTH + self._unit() * (MAX_STRENGTH - MIN_STRENGTH)
        self.alive[i] = True

    def advance(mut self, dt: Float64):
        """Move every blob `dt` seconds, bouncing off the keep-out band."""
        var lo = keep_out()
        var hi = STAGE - lo
        for i in range(MAX_BLOBS):
            if not self.alive[i]:
                continue
            var nx = self.x[i] + self.vx[i] * dt
            var ny = self.y[i] + self.vy[i] * dt
            if nx < lo:
                nx = lo + (lo - nx)
                self.vx[i] = -self.vx[i]
            elif nx > hi:
                nx = hi - (nx - hi)
                self.vx[i] = -self.vx[i]
            if ny < lo:
                ny = lo + (lo - ny)
                self.vy[i] = -self.vy[i]
            elif ny > hi:
                ny = hi - (ny - hi)
                self.vy[i] = -self.vy[i]
            self.x[i] = clamp_centre(nx)
            self.y[i] = clamp_centre(ny)
