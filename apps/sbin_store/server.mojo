"""Serve a directory of SirenBin entities with zero user-space copies.

The zero-copy server story for SirenBin, with no framework changes:

- A producer (the Mojo `publish()` in siren-grail, or anything that renames
  a complete file into place) drops `<name>.sbin` files into a directory.
- This app mounts that directory with `StaticFiles`, so every entity is
  served by `sendfile(2)` from the page cache: the body never enters this
  process. ETag / If-None-Match (304) and byte ranges (206) come with it.
  The only addition is the content type, `application/vnd.siren+bin`.
- `/events` is an SSE stream. The app's `tick` scans the directory and
  emits `entity-changed` / `entity-removed` with the entity's current ETag,
  so a client holding a cached buffer refetches only what actually changed
  (and gets a 304 when its copy is still current).

Routes:
    GET  /health                    liveness + subscriber count
    GET  /entities/                 JSON list of entity names
    GET  /entities/<name>.sbin      the entity (sendfile; ETag; ranges)
    GET  /events                    SSE: entity-changed | entity-removed

Environment:
    M0_SBIN_DIR      directory to serve (default: apps/sbin_store/data)
    M0_PORT          port (AppConfig)
    M0_APP_TICK_MS   scan cadence; forced to 100 ms when unset
"""

from std.collections import List
from std.os import listdir, stat, getenv

from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from lightbug_http.header import Headers, Header, HeaderKey
from m0_http import AppConfig, install_shutdown_signals
from m0_http.static import StaticFiles, stat_etag
from m0_http.sse import SSERegistry, sse_response


comptime SBIN_EXT = ".sbin"
comptime SBIN_TYPE = "application/vnd.siren+bin"
comptime MOUNT = "/entities/"
comptime EVENTS_URL = "/events"


def _json_str(s: String) -> String:
    """Quote a string for a JSON payload (names are filenames, so only the
    two characters that can break a string literal need escaping)."""
    var out = String('"')
    for ch in s.codepoint_slices():
        if ch == '"':
            out += '\\"'
        elif ch == "\\":
            out += "\\\\"
        else:
            out += ch
    out += '"'
    return out


def _strip_ext(name: String) -> String:
    return String(name[byte = : name.byte_length() - SBIN_EXT.byte_length()])


def _json(status: Int, text: String, body: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=body.as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "application/json")),
        status_code=status,
        status_text=text,
    )


struct SbinStoreHandler(HTTPService):
    var root: String
    var files: StaticFiles
    var registry: SSERegistry
    # Directory snapshot from the last scan, struct-of-arrays: a name and
    # the stamp (size + mtime_ns) it was seen with.
    var names: List[String]
    var stamps: List[String]
    var next_event_id: Int
    var _last_scan_ms: Int
    var scan_every_ms: Int

    def __init__(out self, var root: String, scan_every_ms: Int):
        self.files = StaticFiles(root, MOUNT)
        self.root = root^
        # Must be at least the server's max connections: slots are indexed
        # directly by req.slot_id.
        self.registry = SSERegistry(1024)
        self.names = List[String]()
        self.stamps = List[String]()
        self.next_event_id = 1
        self._last_scan_ms = 0
        self.scan_every_ms = scan_every_ms
        # Prime the snapshot so the first tick does not announce every file.
        _ = self._scan(announce=False)

    # --- Requests ----------------------------------------------------------

    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var path = req.uri.path

        if path == "/health":
            return OK(
                '{"status":"ok","entities":' + String(len(self.names))
                + ',"subscribers":' + String(self.registry.subscriber_count(EVENTS_URL)) + "}",
                "application/json",
            )

        if path == EVENTS_URL:
            if req.slot_id < 0:
                return _json(409, "Conflict", '{"error":"streaming needs the non-blocking server"}')
            var last_id = 0
            var lei = req.headers.get("last-event-id")
            if lei:
                try:
                    last_id = Int(lei.value())
                except:
                    last_id = 0
            self.registry.subscribe(req.slot_id, EVENTS_URL, last_id)
            return sse_response()

        if path == MOUNT or path == "/entities":
            return _json(200, "OK", self._listing())

        if path.startswith(MOUNT):
            var hit = self.files.serve(req)
            if hit:
                var resp = hit.take()
                # StaticFiles answers 200/206 with a Content-Type by extension
                # (octet-stream for .sbin); a SirenBin client negotiates on the
                # vendor type, so name it. 304/405/416 carry no body type.
                if path.endswith(SBIN_EXT) and (resp.status_code == 200 or resp.status_code == 206):
                    resp.headers[HeaderKey.CONTENT_TYPE] = SBIN_TYPE
                return resp^
            return _json(404, "Not Found", '{"error":"no such entity"}')

        return _json(404, "Not Found", '{"error":"not found"}')

    def _listing(self) -> String:
        var out = String('{"entities":[')
        for i in range(len(self.names)):
            if i > 0:
                out += ","
            out += _json_str(_strip_ext(self.names[i]))
        out += "]}"
        return out

    # --- SSE hooks ---------------------------------------------------------

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return self.registry.drain(slot)

    def sse_is_streaming(self, slot: Int) -> Bool:
        return self.registry.is_slot_streaming(slot)

    def sse_slot_disconnected(mut self, slot: Int):
        self.registry.unsubscribe(slot)

    # --- Directory scan ----------------------------------------------------

    def tick(mut self, now_ms: Int):
        if now_ms - self._last_scan_ms < self.scan_every_ms:
            return
        self._last_scan_ms = now_ms
        _ = self._scan(announce=True)

    def _stamp_and_etag(self, name: String) -> Tuple[String, String]:
        """(stamp, etag) for a file, or ("", "") if it cannot be stat'ed.

        The ETag is computed exactly as StaticFiles computes it, so the value
        in an event equals the one a GET returns: a client can compare the
        two without a request.
        """
        try:
            var st = stat(self.root + "/" + name)
            var mtime_ns = Int(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int(st.st_mtimespec.tv_subsec)
            var size = Int(st.st_size)
            return (String(size) + ":" + String(mtime_ns), stat_etag(size, mtime_ns))
        except:
            return (String(""), String(""))

    def _find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def _emit(mut self, event_type: String, name: String, etag: String):
        var data = '{"name":' + _json_str(_strip_ext(name))
        if etag.byte_length() > 0:
            data += ',"etag":' + _json_str(etag)
        data += "}"
        var id = self.next_event_id
        self.next_event_id += 1
        _ = self.registry.notify(EVENTS_URL, id, event_type, data)

    def _scan(mut self, announce: Bool) -> Int:
        """Rescan the directory. Returns the number of changes announced."""
        var entries: List[String]
        try:
            entries = listdir(self.root)
        except:
            return 0

        var seen = List[Bool](capacity=len(self.names))
        for _ in range(len(self.names)):
            seen.append(False)

        var changes = 0
        for e in entries:
            var name = String(e)
            if not name.endswith(SBIN_EXT):
                continue
            var probe = self._stamp_and_etag(name)
            var stamp = probe[0]
            var etag = probe[1]
            if stamp.byte_length() == 0:
                continue
            var idx = self._find(name)
            if idx < 0:
                self.names.append(name)
                self.stamps.append(stamp)
                seen.append(True)
                if announce:
                    self._emit("entity-changed", name, etag)
                    changes += 1
            else:
                seen[idx] = True
                if self.stamps[idx] != stamp:
                    self.stamps[idx] = stamp
                    if announce:
                        self._emit("entity-changed", name, etag)
                        changes += 1

        # Removed files, back to front so indices stay valid.
        var i = len(self.names) - 1
        while i >= 0:
            if not seen[i]:
                var gone = self.names[i]
                _ = self.names.pop(i)
                _ = self.stamps.pop(i)
                if announce:
                    self._emit("entity-removed", gone, String(""))
                    changes += 1
            i -= 1
        return changes


def main() raises:
    var config = AppConfig()
    if config.app_tick_ms == 0:
        config.app_tick_ms = 100
    var root = String(getenv("M0_SBIN_DIR"))
    if root.byte_length() == 0:
        root = "apps/sbin_store/data"
    print("sbin_store: serving " + root + " at " + config.address() + MOUNT
          + " (SSE on " + EVENTS_URL + ", scan every " + String(config.app_tick_ms) + " ms)")

    var handler = SbinStoreHandler(root^, config.app_tick_ms)
    var server = Server(config.server_config())
    var shutdown_fd = install_shutdown_signals()
    # The non-blocking loop is required: only it assigns req.slot_id, drains
    # SSE outboxes and fires tick().
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
