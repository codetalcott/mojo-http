from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK
from m0_http import AppConfig, install_shutdown_signals


@fieldwise_init
struct HelloHandler(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.request_uri == "/health":
            return OK('{"status":"ok"}', "application/json")
        return OK("hello from m0", "text/plain")

def main() raises:
    # Reads M0_PORT and M0_ACCESS_LOG. This is the app `scripts/bench_hello.sh`
    # drives, and being able to move its port and toggle access logging without
    # a rebuild is worth the two lines.
    var config = AppConfig()
    print("Starting hello server on " + config.address())
    var server = Server(config.server_config())
    var handler = HelloHandler()
    # The non-blocking loop multiplexes keep-alive connections instead of
    # serving one at a time — measurably better tail latency under
    # concurrent clients, and the same one-liner to call.
    # SIGTERM (docker stop) and SIGINT (Ctrl-C) now reach the loop's graceful
    # drain instead of severing every open connection. -1 back means signal
    # shutdown could not be armed, which is also the server's "no shutdown
    # pipe" sentinel, so there is nothing to branch on here.
    var shutdown_fd = install_shutdown_signals()
    server.listen_and_serve_nonblocking(
        config.address(), handler, shutdown_read_fd=shutdown_fd
    )
