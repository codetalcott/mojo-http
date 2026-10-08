"""A test-only server: each request the loop hands over is answered with what
the application saw, so a client can tell a request served from one refused.

The answer is 200 and one JSON object of hex strings (bytes stay exact
whatever they are): the method, the target, `request_uri`, the host, the
protocol, every header line as received, the body's length and its first 512
bytes. Every refusal is the loop's own, before this handler runs, so any
other status is a request the server did not serve.

`poe smoke-differential` builds and serves it for
`scripts/differential_probe.py`, which sends `scripts/differential_corpus.py`
and compares what came back with the frozen table (SPEC B25). The entry file
is not `server.mojo`, so `build-apps` skips it: the smoke compiles it on
every pull request already.
"""
from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from m0_http import AppConfig, install_shutdown_signals


def hexs(b: Span[Byte, _]) -> String:
    comptime H = "0123456789abcdef"
    var out = String()
    for i in range(len(b)):
        var v = Int(b[i])
        out += H[byte = v >> 4 : (v >> 4) + 1]
        out += H[byte = v & 15 : (v & 15) + 1]
    return out


@fieldwise_init
struct Echo(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        var s = String('{"method":"')
        s += hexs(req.method.as_bytes())
        s += '","target":"'
        s += hexs(req.uri.full_uri.as_bytes())
        s += '","request_uri":"'
        s += hexs(req.uri.request_uri.as_bytes())
        s += '","host":"'
        s += hexs(req.uri.host.as_bytes())
        s += '","protocol":"'
        s += hexs(req.protocol.as_bytes())
        s += '","headers":['
        for i in range(req.headers.count()):
            if i > 0:
                s += ","
            s += '["'
            s += hexs(req.headers.name_span(i))
            s += '","'
            s += hexs(req.headers.value_span(i))
            s += '"]'
        s += '],"body_len":'
        s += String(len(req.body_raw))
        s += ',"body":"'
        var n = len(req.body_raw)
        if n > 512:
            n = 512
        s += hexs(Span(req.body_raw)[:n])
        s += '"}'
        return OK(s, "application/json")


def main() raises:
    var config = AppConfig()
    print("request echo on " + config.address())
    var server = Server(config.server_config())
    var handler = Echo()
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
