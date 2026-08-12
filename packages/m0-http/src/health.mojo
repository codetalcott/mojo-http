"""Health and readiness check registry for M0 HTTP servers.

Provides a HealthRegistry with named boolean checks that serializes
to JSON for /health and /ready endpoints. Readiness includes a
shutting_down flag for graceful shutdown integration.

Usage::

    var health = HealthRegistry()
    health.register("store", True)
    # ... later:
    var json = health.to_json()  # {"status":"ok","checks":{"store":true}}
    var ready = health.is_ready()  # True if all checks pass and not shutting down
"""

from m0_core.json_escape import escape_json_string


struct HealthRegistry(Movable):
    """Named health check registry (SoA)."""
    var check_names: List[String]
    var check_values: List[Bool]
    var shutting_down: Bool

    def __init__(out self):
        self.check_names = List[String]()
        self.check_values = List[Bool]()
        self.shutting_down = False

    def __init__(out self, *, deinit move: Self):
        self.check_names = move.check_names^
        self.check_values = move.check_values^
        self.shutting_down = move.shutting_down

    def register(mut self, name: String, healthy: Bool = True):
        """Register or update a named health check."""
        for i in range(len(self.check_names)):
            if self.check_names[i] == name:
                self.check_values[i] = healthy
                return
        self.check_names.append(name)
        self.check_values.append(healthy)

    def set(mut self, name: String, healthy: Bool):
        """Update a previously registered check."""
        for i in range(len(self.check_names)):
            if self.check_names[i] == name:
                self.check_values[i] = healthy
                return

    def is_ready(self) -> Bool:
        """True if all checks pass and not shutting down."""
        if self.shutting_down:
            return False
        for i in range(len(self.check_values)):
            if not self.check_values[i]:
                return False
        return True

    def to_json(self) -> String:
        """Serialize to JSON for /health endpoint."""
        var status = String("ok")
        for i in range(len(self.check_values)):
            if not self.check_values[i]:
                status = "degraded"
                break
        if self.shutting_down:
            status = "shutting_down"

        var out = String('{"status":') + escape_json_string(status)
        if len(self.check_names) > 0:
            out += ',"checks":{'
            for i in range(len(self.check_names)):
                if i > 0:
                    out += ","
                out += escape_json_string(self.check_names[i]) + ":"
                if self.check_values[i]:
                    out += "true"
                else:
                    out += "false"
            out += "}"
        out += "}"
        return out^

    def ready_status_code(self) -> Int:
        """Return 200 if ready, 503 if not."""
        if self.is_ready():
            return 200
        return 503
