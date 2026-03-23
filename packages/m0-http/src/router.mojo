"""Simple HTTP router with parameterized path matching.

Supports exact paths (/orders) and :param segments (/orders/:id).
Linear scan over <10 routes — simpler and faster than regex.
"""


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


struct Route(Copyable, Movable):
    var method: String
    var segments: List[String]
    var handler_id: Int
    var param_count: Int

    def __init__(out self, method: String, pattern: String, handler_id: Int):
        self.method = method
        self.handler_id = handler_id
        self.param_count = 0
        self.segments = List[String]()
        var parts = pattern.split("/")
        for i in range(len(parts)):
            var p = String(parts[i])
            if len(p) > 0:
                self.segments.append(p)
                if p.startswith(":"):
                    self.param_count += 1


struct Router:
    """HTTP router with parameterized path matching."""
    var routes: List[Route]

    def __init__(out self):
        self.routes = List[Route]()

    def add(mut self, method: String, pattern: String, handler_id: Int):
        """Register a route. Pattern uses :param for captures."""
        self.routes.append(Route(method, pattern, handler_id))

    def match(self, method: String, path: String) -> MatchResult:
        """Match method + path against registered routes.

        Distinguishes 404 (no path match) from 405 (path matched,
        wrong method).
        """
        var req_segments = List[String]()
        var parts = path.split("/")
        for i in range(len(parts)):
            var p = String(parts[i])
            if len(p) > 0:
                req_segments.append(p)

        var req_count = len(req_segments)
        var path_matched = False

        for i in range(len(self.routes)):
            if len(self.routes[i].segments) != req_count:
                continue

            var params = List[String]()
            var matched = True
            for j in range(req_count):
                var rs = String(self.routes[i].segments[j])
                if len(rs) > 0 and rs.startswith(":"):
                    params.append(req_segments[j])
                elif rs != req_segments[j]:
                    matched = False
                    break

            if not matched:
                continue

            if self.routes[i].method == method:
                return MatchResult(self.routes[i].handler_id, params^)
            path_matched = True

        if path_matched:
            var r = MatchResult()
            r.method_not_allowed = True
            return r^

        return MatchResult()
