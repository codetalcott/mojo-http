"""World to shapes: the metaball step, behind the contract the wire relies on.

Five stages, run once per producer step on buffers a `Tracer` keeps:

1. **Field.** Every blob adds `strength / (d^2 + 1)` at each point of a
   `W x H` grid, a row at a time in SIMD lanes. The grid's outer ring is
   then forced to zero.
2. **March.** Marching squares turns each cell the field crosses `ISO` in
   into one segment (two for a saddle), each named by the grid EDGES it
   starts and ends on.
3. **Chain.** Segments join where one ends on the edge the next starts on,
   into closed cycles.
4. **Resample.** Each outer cycle becomes exactly `NVERT` vertices spaced
   by arc length, vertex 0 its topmost (ties: leftmost).
5. **Match.** Each polygon takes the slot whose previous polygon was
   nearest, so a slot follows one blob instead of jumping across the stage.

Five rules, each of which cost a round to find, and each held by a test
in `test/test_kernel.mojo` that fails when the rule is broken
(`poe sabotage-blobs` breaks each on purpose):

- **Complementary cases wind oppositely.** Case 1 and case 14 cut a cell
  the same way and must run in opposite directions, so the contour keeps
  the inside on one side. Written as one case, every contour fragments.
- **Chain on edge identity, never on coordinates.** A crossing belongs to
  the grid edge it lies on — horizontal `y*W + x`, vertical
  `W*H + y*W + x` — shared by exactly the two cells that meet there.
  Keyed on rounded coordinates, crossings a fraction of a cell apart
  collide and the walk jumps between contours.
- **The border closes every contour.** A contour the grid edge cuts is an
  open path, and `polygon()` cannot draw one. Clamping blob CENTRES does
  not prevent it once blobs merge: sixteen at one point reach ~45 grid
  units, against a clamp of ~23. With the outer ring forced below `ISO`,
  every contour closes inside the grid, and a cluster pressed against a
  wall is drawn flattened against it. (The prototype walked path heads
  first to trace an open path whole; with no open paths that ordering
  has nothing to order, and a chain that still finds one is counted as a
  kernel fault in `open_paths`.)
- **Holes are dropped.** The march keeps the inside on the left, which in
  page coordinates (y down) gives an outer contour a NEGATIVE shoelace
  area and a hole a positive one. The prototype emitted a hole as a
  polygon of its own; a `clip-path` cannot cut one out, so it is dropped.
- **Vertex 0 is chosen after resampling.** CSS moves vertex `i` to vertex
  `i`, so the start must not wander between frames; picking it among the
  resampled vertices makes the rule exact rather than exact up to
  rounding in the interpolation.

The contract the wire and the page depend on, per filled slot: exactly
`NVERT` vertices in grid units strictly inside the stage; vertex 0 the
topmost, ties leftmost; negative shoelace area. At most one slot per live
blob is filled, and at least one while any blob lives.
"""

from std.math import iota, sqrt
from std.sys.info import simd_width_of

from blobs.world import MAX_BLOBS, World

comptime W = 192
"""Grid columns: one sample per stage unit."""

comptime H = 192
"""Grid rows."""

comptime ISO = Float32(1.0)
"""The field value a contour follows."""

comptime NVERT = 48
"""Vertices per polygon. CSS interpolates `polygon()` only between equal counts."""

comptime SLOTS = MAX_BLOBS
"""Polygons per frame: merged blobs make fewer, never more."""

comptime MIN_LOOP = 8
"""A cycle of fewer segments than this is a speck, not a blob."""

comptime MATCH_RADIUS = Float32(40.0)
"""How far, in grid units, a polygon's centre may move and keep its slot."""

comptime _LANES = simd_width_of[DType.float32]()


struct Shapes(Movable):
    """`SLOTS x NVERT` vertices in grid units, which slots hold one, and
    each slot's centre — kept between steps, which is what slot matching
    reads."""

    var px: List[Float32]
    var py: List[Float32]
    var filled: List[Bool]
    var cx: List[Float32]
    var cy: List[Float32]

    def __init__(out self):
        self.px = List[Float32](length=SLOTS * NVERT, fill=0.0)
        self.py = List[Float32](length=SLOTS * NVERT, fill=0.0)
        self.filled = List[Bool](length=SLOTS, fill=False)
        self.cx = List[Float32](length=SLOTS, fill=0.0)
        self.cy = List[Float32](length=SLOTS, fill=0.0)

    def filled_count(self) -> Int:
        var n = 0
        for k in range(SLOTS):
            if self.filled[k]:
                n += 1
        return n


def _lerp(a: Float32, ca: Float32, cb: Float32) -> Float32:
    """Where between `a` and `a + 1` the field crosses `ISO`."""
    var d = cb - ca
    if d == 0:
        return a
    return a + (ISO - ca) / d


struct Tracer(Movable):
    """The kernel's working buffers and the last step's counts.

    One per producer, reused every step: the field and the edge maps are
    sized once. The edge maps are stamped with a generation rather than
    cleared, so a step touches only the entries its own segments wrote.
    """

    var field: List[Float32]
    var seg_x: List[Float32]
    """Each segment's start point."""
    var seg_y: List[Float32]
    var seg_from: List[Int]
    """The grid edge each segment starts on."""
    var seg_to: List[Int]
    """The grid edge each segment ends on."""
    var starts_at: List[Int]
    """Indexed by grid edge: the segment starting there, valid when stamped."""
    var stamp: List[Int]
    var gen: Int
    var used: List[Bool]
    var loop_x: List[Float32]
    var loop_y: List[Float32]
    var loop_bounds: List[Int]
    var cand_x: List[Float32]
    """Resampled candidates, `NVERT` per polygon."""
    var cand_y: List[Float32]
    var cand_area: List[Float32]
    var bx: List[Float32]
    var by: List[Float32]
    var bs: List[Float32]

    var segments: Int
    """Segments the last step marched."""
    var cycles: Int
    """Closed cycles it chained, holes and specks included."""
    var cycle_segments: Int
    """Segments that ended up in a closed cycle."""
    var open_paths: Int
    """Walks that did not close. Zero by construction: nonzero is a fault."""
    var holes: Int
    """Cycles dropped for winding the hole's way."""
    var kept: Int
    """Polygons the last step drew."""

    def __init__(out self):
        self.field = List[Float32](length=W * H, fill=0.0)
        self.seg_x = List[Float32]()
        self.seg_y = List[Float32]()
        self.seg_from = List[Int]()
        self.seg_to = List[Int]()
        self.starts_at = List[Int](length=2 * W * H, fill=0)
        self.stamp = List[Int](length=2 * W * H, fill=0)
        self.gen = 0
        self.used = List[Bool]()
        self.loop_x = List[Float32]()
        self.loop_y = List[Float32]()
        self.loop_bounds = List[Int]()
        self.cand_x = List[Float32]()
        self.cand_y = List[Float32]()
        self.cand_area = List[Float32]()
        self.bx = List[Float32]()
        self.by = List[Float32]()
        self.bs = List[Float32]()
        self.segments = 0
        self.cycles = 0
        self.cycle_segments = 0
        self.open_paths = 0
        self.holes = 0
        self.kept = 0

    def trace(mut self, world: World, mut shapes: Shapes):
        """One step: the world's blobs to `shapes`, slots matched to last step's."""
        self.sample(world)
        self.march()
        self.chain()
        self.resample()
        self.match(shapes)

    # --- 1. field -------------------------------------------------------------

    def sample(mut self, world: World):
        self.bx.clear()
        self.by.clear()
        self.bs.clear()
        for i in range(MAX_BLOBS):
            if world.alive[i]:
                self.bx.append(Float32(world.x[i]))
                self.by.append(Float32(world.y[i]))
                self.bs.append(Float32(world.strength[i]))
        var nb = len(self.bx)
        var p = self.field.unsafe_ptr()
        var lanes = iota[DType.float32, _LANES]()
        for y in range(H):
            var fy = Float32(y)
            var x = 0
            while x + _LANES <= W:
                var xs = lanes + Float32(x)
                var acc = SIMD[DType.float32, _LANES](0)
                for b in range(nb):
                    var dx = xs - self.bx[b]
                    var dy = fy - self.by[b]
                    acc += self.bs[b] / (dx * dx + dy * dy + 1.0)
                p.unsafe_offset(y * W + x).unsafe_store(acc)
                x += _LANES
            while x < W:
                var s = Float32(0)
                for b in range(nb):
                    var dx = Float32(x) - self.bx[b]
                    var dy = fy - self.by[b]
                    s += self.bs[b] / (dx * dx + dy * dy + 1.0)
                self.field[y * W + x] = s
                x += 1
        self._close_border()

    def _close_border(mut self):
        """Force the grid's outer ring below `ISO`: every contour closes."""
        for x in range(W):
            self.field[x] = 0.0
            self.field[(H - 1) * W + x] = 0.0
        for y in range(H):
            self.field[y * W] = 0.0
            self.field[y * W + W - 1] = 0.0

    # --- 2. march -------------------------------------------------------------

    def _emit(
        mut self,
        x0: Float32, y0: Float32, x1: Float32, y1: Float32,
        from_edge: Int, to_edge: Int,
    ):
        """One segment from (`x0`, `y0`) on `from_edge` to (`x1`, `y1`) on
        `to_edge`. Only the start point is kept: the next segment's start is
        this one's end, and the chain is keyed on the edges alone."""
        self.seg_x.append(x0)
        self.seg_y.append(y0)
        self.seg_from.append(from_edge)
        self.seg_to.append(to_edge)

    def march(mut self):
        """Corners c0 top-left, c1 top-right, c2 bottom-right, c3 bottom-left;
        bits 1/2/4/8; inside means above `ISO`; inside kept on the left."""
        self.seg_x.clear()
        self.seg_y.clear()
        self.seg_from.clear()
        self.seg_to.clear()
        for y in range(H - 1):
            for x in range(W - 1):
                var i = y * W + x
                var c0 = self.field[i]
                var c1 = self.field[i + 1]
                var c2 = self.field[i + W + 1]
                var c3 = self.field[i + W]
                var code = 0
                if c0 > ISO:
                    code += 1
                if c1 > ISO:
                    code += 2
                if c2 > ISO:
                    code += 4
                if c3 > ISO:
                    code += 8
                if code == 0 or code == 15:
                    continue
                var fx = Float32(x)
                var fy = Float32(y)
                var e_t = y * W + x
                var e_b = (y + 1) * W + x
                var e_l = W * H + y * W + x
                var e_r = W * H + y * W + x + 1
                var tx = _lerp(fx, c0, c1)
                var ry = _lerp(fy, c1, c2)
                var bx = _lerp(fx, c3, c2)
                var ly = _lerp(fy, c0, c3)
                var rx = fx + 1.0
                var by = fy + 1.0
                # Each case its OWN direction: a complementary pair has the
                # same geometry and the opposite winding.
                if code == 1:
                    self._emit(fx, ly, tx, fy, e_l, e_t)
                elif code == 14:
                    self._emit(tx, fy, fx, ly, e_t, e_l)
                elif code == 2:
                    self._emit(tx, fy, rx, ry, e_t, e_r)
                elif code == 13:
                    self._emit(rx, ry, tx, fy, e_r, e_t)
                elif code == 4:
                    self._emit(rx, ry, bx, by, e_r, e_b)
                elif code == 11:
                    self._emit(bx, by, rx, ry, e_b, e_r)
                elif code == 8:
                    self._emit(bx, by, fx, ly, e_b, e_l)
                elif code == 7:
                    self._emit(fx, ly, bx, by, e_l, e_b)
                elif code == 3:
                    self._emit(fx, ly, rx, ry, e_l, e_r)
                elif code == 12:
                    self._emit(rx, ry, fx, ly, e_r, e_l)
                elif code == 6:
                    self._emit(tx, fy, bx, by, e_t, e_b)
                elif code == 9:
                    self._emit(bx, by, tx, fy, e_b, e_t)
                elif code == 5:
                    self._emit(fx, ly, tx, fy, e_l, e_t)
                    self._emit(rx, ry, bx, by, e_r, e_b)
                else:
                    self._emit(tx, fy, rx, ry, e_t, e_r)
                    self._emit(bx, by, fx, ly, e_b, e_l)
        self.segments = len(self.seg_x)

    # --- 3. chain -------------------------------------------------------------

    def chain(mut self):
        var n = self.segments
        self.gen += 1
        var gen = self.gen
        for s in range(n):
            self.starts_at[self.seg_from[s]] = s
            self.stamp[self.seg_from[s]] = gen
        self.used.clear()
        self.used.resize(n, False)
        self.loop_x.clear()
        self.loop_y.clear()
        self.loop_bounds.clear()
        self.loop_bounds.append(0)
        self.cycles = 0
        self.cycle_segments = 0
        self.open_paths = 0
        for s in range(n):
            if self.used[s]:
                continue
            var begin = len(self.loop_x)
            var cur = s
            var closed = False
            while True:
                self.used[cur] = True
                self.loop_x.append(self.seg_x[cur])
                self.loop_y.append(self.seg_y[cur])
                var e = self.seg_to[cur]
                if self.stamp[e] != gen:
                    break
                var nxt = self.starts_at[e]
                if nxt == s:
                    closed = True
                    break
                if self.used[nxt]:
                    break
                cur = nxt
            if closed:
                self.cycles += 1
                self.cycle_segments += len(self.loop_x) - begin
                self.loop_bounds.append(len(self.loop_x))
            else:
                self.open_paths += 1
                self.loop_x.resize(begin, 0.0)
                self.loop_y.resize(begin, 0.0)

    # --- 4. resample ------------------------------------------------------------

    def resample(mut self):
        self.cand_x.clear()
        self.cand_y.clear()
        self.cand_area.clear()
        self.holes = 0
        for li in range(len(self.loop_bounds) - 1):
            var a = self.loop_bounds[li]
            var cnt = self.loop_bounds[li + 1] - a
            if cnt < MIN_LOOP:
                continue
            var area = Float32(0)
            var per = Float32(0)
            for i in range(cnt):
                var j = (i + 1) % cnt
                var x0 = self.loop_x[a + i]
                var y0 = self.loop_y[a + i]
                var x1 = self.loop_x[a + j]
                var y1 = self.loop_y[a + j]
                area += x0 * y1 - x1 * y0
                var dx = x1 - x0
                var dy = y1 - y0
                per += sqrt(dx * dx + dy * dy)
            if not (area < 0):
                self.holes += 1
                continue
            if per <= 0:
                continue
            var base = len(self.cand_x)
            var step = per / Float32(NVERT)
            var acc = Float32(0)
            var target = Float32(0)
            var emitted = 0
            var i = 0
            while emitted < NVERT and i < cnt:
                var j = (i + 1) % cnt
                var px = self.loop_x[a + i]
                var py = self.loop_y[a + i]
                var dx = self.loop_x[a + j] - px
                var dy = self.loop_y[a + j] - py
                var seglen = sqrt(dx * dx + dy * dy)
                while emitted < NVERT and target <= acc + seglen:
                    var t = Float32(0)
                    if seglen > 0:
                        t = (target - acc) / seglen
                    self.cand_x.append(px + dx * t)
                    self.cand_y.append(py + dy * t)
                    emitted += 1
                    target = step * Float32(emitted)
                acc += seglen
                i += 1
            while emitted < NVERT:
                # Unreachable in practice: the last target sits a whole step
                # short of the perimeter.
                self.cand_x.append(self.cand_x[len(self.cand_x) - 1])
                self.cand_y.append(self.cand_y[len(self.cand_y) - 1])
                emitted += 1
            # Vertex 0: the topmost resampled vertex, ties leftmost.
            var best = 0
            for v in range(1, NVERT):
                var y = self.cand_y[base + v]
                var by = self.cand_y[base + best]
                if y < by or (y == by and self.cand_x[base + v] < self.cand_x[base + best]):
                    best = v
            if best > 0:
                _rotate(self.cand_x, base, best)
                _rotate(self.cand_y, base, best)
            self.cand_area.append(-area / 2.0)

    # --- 5. match -------------------------------------------------------------

    def match(mut self, mut shapes: Shapes):
        """Give each polygon a slot: the nearest one it held, else a free one.

        Largest first, so when blobs merge the merged shape keeps the
        biggest one's slot, and when more polygons exist than slots the
        smallest are the ones left out. A new polygon prefers a slot that
        was empty last step: one that just emptied would animate its old
        shape across the stage to the new one.
        """
        var ncand = len(self.cand_area)
        var order = List[Int]()
        for c in range(ncand):
            var pos = len(order)
            while pos > 0 and self.cand_area[order[pos - 1]] < self.cand_area[c]:
                pos -= 1
            order.insert(pos, c)
        if len(order) > SLOTS:
            order.resize(SLOTS, 0)
        var was = shapes.filled.copy()
        var taken = List[Bool](length=SLOTS, fill=False)
        var slot_of = List[Int](length=len(order), fill=-1)
        var mx = List[Float32](length=len(order), fill=0.0)
        var my = List[Float32](length=len(order), fill=0.0)
        for oi in range(len(order)):
            var c = order[oi]
            var sx = Float32(0)
            var sy = Float32(0)
            for v in range(NVERT):
                sx += self.cand_x[c * NVERT + v]
                sy += self.cand_y[c * NVERT + v]
            mx[oi] = sx / Float32(NVERT)
            my[oi] = sy / Float32(NVERT)
            var best = -1
            var best_d = MATCH_RADIUS * MATCH_RADIUS
            for k in range(SLOTS):
                if not was[k] or taken[k]:
                    continue
                var dx = shapes.cx[k] - mx[oi]
                var dy = shapes.cy[k] - my[oi]
                var d = dx * dx + dy * dy
                if d < best_d:
                    best_d = d
                    best = k
            if best >= 0:
                taken[best] = True
                slot_of[oi] = best
        for oi in range(len(order)):
            if slot_of[oi] >= 0:
                continue
            var pick = -1
            for k in range(SLOTS):
                if not taken[k] and not was[k]:
                    pick = k
                    break
            if pick < 0:
                for k in range(SLOTS):
                    if not taken[k]:
                        pick = k
                        break
            taken[pick] = True
            slot_of[oi] = pick
        for k in range(SLOTS):
            shapes.filled[k] = taken[k]
        for oi in range(len(order)):
            var c = order[oi]
            var k = slot_of[oi]
            for v in range(NVERT):
                shapes.px[k * NVERT + v] = self.cand_x[c * NVERT + v]
                shapes.py[k * NVERT + v] = self.cand_y[c * NVERT + v]
            shapes.cx[k] = mx[oi]
            shapes.cy[k] = my[oi]
        self.kept = len(order)


def _rotate(mut xs: List[Float32], base: Int, by: Int):
    """Rotate `xs[base : base + NVERT]` left by `by`."""
    var tmp = List[Float32](capacity=NVERT)
    for v in range(NVERT):
        tmp.append(xs[base + (v + by) % NVERT])
    for v in range(NVERT):
        xs[base + v] = tmp[v]
