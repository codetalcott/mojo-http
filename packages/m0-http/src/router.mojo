"""HTTP router with parameterized path matching.

Supports exact paths (`/orders`) and `:param` segments (`/orders/:id`).
A linear scan over a handful of routes — simpler and faster than regex.

Patterns live in one flat byte blob indexed by parallel (offset, length)
arrays, the SoA pattern `Headers` uses for the same reason. The previous
representation held a `List[String]` of segments per route and rebuilt a
`String` for **every segment of every candidate route** on every request,
plus a `List[String]` for the request path — so a routing decision that
returns a single integer allocated dozens of times.

Matching now walks the path by moving span endpoints and compares bytes
against the blob. Nothing is allocated until a parameter is captured on a
route that actually matched; a 404 allocates nothing at all.

Segment boundaries are recomputed per candidate route rather than recorded
once up front. That costs a second pass over a short path for the few
routes sharing a segment count with the request — routes with a different
count are rejected before any scanning — and in exchange the matcher needs
no scratch storage and imposes no cap on path depth.
"""

comptime _SLASH = UInt8(47)  # '/'
comptime _COLON = UInt8(58)  # ':'


struct MatchResult(Copyable, Movable):
    """Result of matching a request against registered routes."""
    var matched: Bool
    var method_not_allowed: Bool
    var handler_id: Int
    var params: List[String]

    def __init__(out self):
        self.matched = False
        self.method_not_allowed = False
        self.handler_id = -1
        self.params = List[String]()

    def __init__(out self, handler_id: Int, var params: List[String]):
        self.matched = True
        self.method_not_allowed = False
        self.handler_id = handler_id
        self.params = params^


struct Router:
    """HTTP router with parameterized path matching."""

    var _buf: List[Byte]
    """Every method and every pattern segment, back to back."""
    var _seg_off: List[Int32]
    """Offset into `_buf` of each pattern segment, all routes concatenated."""
    var _seg_len: List[Int32]
    var _seg_is_param: List[Bool]
    """Whether the segment was written `:name` — matches anything, captures."""
    var _r_seg_start: List[Int32]
    """Index into the segment arrays where each route's segments begin."""
    var _r_seg_count: List[Int32]
    var _r_meth_off: List[Int32]
    var _r_meth_len: List[Int32]
    var _r_handler: List[Int32]
    var _r_param_count: List[Int32]

    def __init__(out self):
        self._buf = List[Byte]()
        self._seg_off = List[Int32]()
        self._seg_len = List[Int32]()
        self._seg_is_param = List[Bool]()
        self._r_seg_start = List[Int32]()
        self._r_seg_count = List[Int32]()
        self._r_meth_off = List[Int32]()
        self._r_meth_len = List[Int32]()
        self._r_handler = List[Int32]()
        self._r_param_count = List[Int32]()

    def add(mut self, method: String, pattern: String, handler_id: Int):
        """Register a route. Pattern uses `:param` for captures."""
        var m_off = len(self._buf)
        self._buf.extend(method.as_bytes())
        self._r_meth_off.append(Int32(m_off))
        self._r_meth_len.append(Int32(method.byte_length()))
        self._r_seg_start.append(Int32(len(self._seg_off)))

        var pb = pattern.as_bytes()
        var n = len(pb)
        var count = 0
        var params = 0
        var i = 0
        while i < n:
            while i < n and pb[i] == _SLASH:
                i += 1
            if i >= n:
                break
            var start = i
            while i < n and pb[i] != _SLASH:
                i += 1
            var is_param = pb[start] == _COLON
            # A `:name` segment stores only the name. Matching never reads it,
            # but keeping it makes the blob self-describing when debugging.
            var text_start = start + 1 if is_param else start
            var off = len(self._buf)
            self._buf.extend(pb[text_start:i])
            self._seg_off.append(Int32(off))
            self._seg_len.append(Int32(i - text_start))
            self._seg_is_param.append(is_param)
            count += 1
            if is_param:
                params += 1

        self._r_seg_count.append(Int32(count))
        self._r_handler.append(Int32(handler_id))
        self._r_param_count.append(Int32(params))

    @always_inline
    def _segment_eq(self, k: Int, probe: Span[Byte, _]) -> Bool:
        """Whether pattern segment `k` equals `probe`, byte for byte."""
        var l = Int(self._seg_len[k])
        if l != len(probe):
            return False
        var off = Int(self._seg_off[k])
        for j in range(l):
            if self._buf[off + j] != probe[j]:
                return False
        return True

    @always_inline
    def _method_eq(self, r: Int, probe: Span[Byte, _]) -> Bool:
        var l = Int(self._r_meth_len[r])
        if l != len(probe):
            return False
        var off = Int(self._r_meth_off[r])
        for j in range(l):
            if self._buf[off + j] != probe[j]:
                return False
        return True

    @staticmethod
    @always_inline
    def _count_segments(pb: Span[Byte, _]) -> Int:
        var n = len(pb)
        var count = 0
        var i = 0
        while i < n:
            while i < n and pb[i] == _SLASH:
                i += 1
            if i >= n:
                break
            while i < n and pb[i] != _SLASH:
                i += 1
            count += 1
        return count

    def match(self, method: String, path: String) -> MatchResult:
        """Match method + path against registered routes.

        Distinguishes 404 (no path match) from 405 (path matched, wrong
        method).
        """
        var pb = path.as_bytes()
        var n = len(pb)
        var req_count = Self._count_segments(pb)
        var mb = method.as_bytes()
        var path_matched = False

        for r in range(len(self._r_handler)):
            # The cheap rejection first: a route with a different number of
            # segments cannot match, and is dismissed without scanning.
            if Int(self._r_seg_count[r]) != req_count:
                continue

            var base = Int(self._r_seg_start[r])
            var ok = True
            var pos = 0
            for j in range(req_count):
                while pos < n and pb[pos] == _SLASH:
                    pos += 1
                var start = pos
                while pos < n and pb[pos] != _SLASH:
                    pos += 1
                var k = base + j
                if self._seg_is_param[k]:
                    continue  # a param segment matches any non-empty segment
                if not self._segment_eq(k, pb[start:pos]):
                    ok = False
                    break
            if not ok:
                continue

            if not self._method_eq(r, mb):
                path_matched = True
                continue

            # Only now does anything allocate, and only one String per
            # captured parameter. Walking the path a second time is cheaper
            # than having recorded every boundary for routes that missed.
            var params = List[String](capacity=Int(self._r_param_count[r]))
            var cpos = 0
            for j in range(req_count):
                while cpos < n and pb[cpos] == _SLASH:
                    cpos += 1
                var start = cpos
                while cpos < n and pb[cpos] != _SLASH:
                    cpos += 1
                if self._seg_is_param[base + j]:
                    params.append(String(unsafe_from_utf8=pb[start:cpos]))
            return MatchResult(Int(self._r_handler[r]), params^)

        if path_matched:
            var r = MatchResult()
            r.method_not_allowed = True
            return r^

        return MatchResult()
