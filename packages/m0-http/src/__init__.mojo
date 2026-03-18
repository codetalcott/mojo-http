# m0-http: HTTP framework layer for the M0 framework.
#
# Depends on: m0-core (hashing, Result, pipeline)
#
# Planned modules:
#   router              — Path router with :param extraction
#   content_negotiation — Generalized Accept header parsing (HTML, JSON, links+json)
#   etag                — Weak ETag computation (wyhash) and matching
#   response_cache      — URL-keyed response cache (SoA pattern)
#   sse/format          — SSE wire format (id, event, data fields)
#   sse/registry        — SSE subscriber slot management with backpressure
#   sse/journal         — Append-only SSE event log with reconnect replay
#   multiworker         — Fork-based multi-worker supervisor
#   lightbug_http/      — Vendored async HTTP server
