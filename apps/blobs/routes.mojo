"""The blobs demo's routes, as values: each pattern written once."""

comptime PAGE = "/"
"""The stage, with the stream opened from `data-init`."""

comptime EVENTS = "/events"
"""The state stream: the newest frame at open, then one per step."""

comptime DROP = "/drop"
"""POST `{"x": pct, "y": pct}`: drop a blob there, for everyone."""

comptime STATS = "/stats"
"""The producer's counters as JSON — what the gate reads."""

comptime HEALTH = "/health"
"""Liveness, answered on the loop."""

comptime NOW = "/now"
"""A trivial request, answered on the loop; the gate times it during steps."""
