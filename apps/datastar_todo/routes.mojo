"""The todo demo's routes, as values.

Each pattern is written once here and given to both the router (which
matches it) and `url_for` (which reverses it), so the renderer never spells
a path and a misspelled route is a compile error rather than a dead button.
The page's own attributes reach for the same constants.
"""

comptime EVENTS = "/events"
"""The SSE stream every tab opens from `data-init`."""

comptime ADD = "/add"
"""POST: read the `draft` signal, insert, broadcast."""

comptime TOGGLE = "/toggle/:id"
"""POST: flip `done`, broadcast."""

comptime DELETE = "/delete/:id"
"""POST: remove, broadcast."""
