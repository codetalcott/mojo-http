"""Datastar protocol constants (targeting v1.0.0-RC.8).

Constants follow the official Go SDK naming conventions.
Dataline literals include trailing space per protocol spec.
"""

# Version
comptime VERSION = "1.0.0-RC.8"
comptime DATASTAR_KEY = "datastar"

# Default timing
comptime DEFAULT_SSE_RETRY_DURATION = 1000  # milliseconds

# Element patch modes
comptime PATCH_MODE_OUTER = "outer"
comptime PATCH_MODE_INNER = "inner"
comptime PATCH_MODE_REMOVE = "remove"
comptime PATCH_MODE_REPLACE = "replace"
comptime PATCH_MODE_PREPEND = "prepend"
comptime PATCH_MODE_APPEND = "append"
comptime PATCH_MODE_BEFORE = "before"
comptime PATCH_MODE_AFTER = "after"

# Default patch mode
comptime DEFAULT_PATCH_MODE = PATCH_MODE_OUTER

# Event types
comptime EVENT_PATCH_ELEMENTS = "datastar-patch-elements"
comptime EVENT_PATCH_SIGNALS = "datastar-patch-signals"

# Dataline literals (with trailing space per protocol spec)
comptime DL_SELECTOR = "selector "
comptime DL_MODE = "mode "
comptime DL_NAMESPACE = "namespace "
comptime DL_USE_VIEW_TRANSITION = "useViewTransition "
comptime DL_ELEMENTS = "elements "
comptime DL_SIGNALS = "signals "
comptime DL_ONLY_IF_MISSING = "onlyIfMissing "

# Namespaces
comptime NS_HTML = "html"
comptime NS_SVG = "svg"
comptime NS_MATHML = "mathml"


fn js_bool(value: Bool) -> String:
    """Convert a Bool to a JavaScript boolean string."""
    if value:
        return "true"
    return "false"
