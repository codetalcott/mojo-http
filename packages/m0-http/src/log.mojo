"""Structured JSON logging for M0 HTTP servers.

Writes JSON-lines to stdout for machine-parseable access logs and
application events. Fields: ts (epoch ms), level, msg, plus up to 8
key-value pairs.
"""

from m0_core.json_escape import escape_json_string


struct LogEntry(Movable):
    """Structured log entry with key-value pairs (SoA)."""
    var level: String
    var msg: String
    var kv_keys: List[String]
    var kv_values: List[String]

    def __init__(out self, level: String, msg: String):
        self.level = level
        self.msg = msg
        self.kv_keys = List[String]()
        self.kv_values = List[String]()

    def __init__(out self, *, deinit move: Self):
        self.level = move.level^
        self.msg = move.msg^
        self.kv_keys = move.kv_keys^
        self.kv_values = move.kv_values^

    def add(mut self, key: String, value: String):
        self.kv_keys.append(key)
        self.kv_values.append(value)

    def add_int(mut self, key: String, value: Int):
        self.kv_keys.append(key)
        self.kv_values.append(String(value))


def log_json(entry: LogEntry):
    """Write a JSON-lines log entry to stdout."""
    from std.time import perf_counter_ns
    var out = String('{"ts":')
    # Epoch ms approximation from perf_counter_ns (monotonic, not wall clock)
    # For true wall-clock, would need time() FFI — this is good enough for log ordering
    out += String(perf_counter_ns() / 1_000_000)
    out += ',"level":' + escape_json_string(entry.level)
    out += ',"msg":' + escape_json_string(entry.msg)
    for i in range(len(entry.kv_keys)):
        out += ',' + escape_json_string(entry.kv_keys[i]) + ':' + escape_json_string(entry.kv_values[i])
    out += '}'
    print(out)


def log_access(method: String, path: String, status: Int, dur_us: Int, body_size: Int):
    """Convenience: emit a structured access log line."""
    var entry = LogEntry("INFO", "access")
    entry.add("method", method)
    entry.add("path", path)
    entry.add_int("status", status)
    entry.add_int("dur_us", dur_us)
    entry.add_int("bytes", body_size)
    log_json(entry)
