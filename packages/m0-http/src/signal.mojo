"""Shutdown pipe helpers for graceful HTTP server shutdown.

Re-exports create_shutdown_pipe() from lightbug_http and provides
convenience for wiring shutdown into demo servers.

The event loop already supports graceful drain: on detecting shutdown,
it closes the listener, sends SSE close comments, and drains in-flight
requests with a 5s timeout.

Usage::

    from m0_http.signal import create_shutdown_pipe

    var (read_fd, handle) = create_shutdown_pipe()
    # Pass read_fd to server, hold handle
    # Call handle.signal() to trigger shutdown (e.g. from a /shutdown endpoint)

For SIGTERM handling in production, use a reverse proxy or container
runtime that sends shutdown commands, or wire handle.signal() into
a platform-specific signal mechanism.
"""

from lightbug_http.c.pipe import create_shutdown_pipe, ShutdownHandle
