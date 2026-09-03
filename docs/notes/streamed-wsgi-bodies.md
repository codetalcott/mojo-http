# Streamed WSGI bodies — shipped 2026-08-27

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The last buffered shape. A generator the application did not size —
Django's `StreamingHttpResponse`, the thing every Django SSE tutorial
returns — was joined whole by the shim, so a never-ending one never
answered and pinned its `--blocking-threads` thread until the bounded
join abandoned it ([REAL_APP_VALIDATION.md](../REAL_APP_VALIDATION.md),
textshelf). It streams now, and nothing new was invented to do it: a pool
thread is a **second producer on the chunk channel the executor already
streams through** — `P` begin frame, `s` chunks, `e` end, the loop's own
framing and end-of-stream — and the loop's per-slot "is this a channel
stream?" question generalised from "the lane has an ack pair" to "the slot
has an ack fd" (`slot_channel_stream`). What buffers is decided in the
shim in order: an app `Content-Length` (every framework page — the rule
that keeps the wire byte-identical and every bench number unchanged), list
bodies, Django's `HttpResponse`, HEAD, bodiless statuses, `M0-Hold`. Only
pool threads stream; the loop's handler keeps joining.

An adversarial review of the first design found four defects before a
line was written, each now a rule in CLAUDE.md: the `isinstance` rule
would have chunk-streamed every Django page (`HttpResponse` is an
iterable); `slot_is_executor`'s unmounted shortcut would have turned every
`M0-Hold` on the default topology into a chunk-framed, heartbeat-less
stream the moment the channel existed (the chunk pair and the executor's
ack pair are separate switches now); "queue a chunk only if subscribed"
does not cover two writers on a recycled slot (every frame carries a
generation, executors included); and the loop cannot learn "aborted" from
one bool (the abort is a tagged datagram on the completion channel,
checked against the head's generation). Building it found two more:
`Int(Int32(UInt32(0xFFFFFFFF)))` is 4294967295 on Mojo 1.0, not -1, so
the disconnect ack never decoded until sign-extended by hand; and a
stream of small events never exhausts a 16 KB window, so credit alone
never made a thread look at the fd the disconnect arrives on — it polls
before every piece now. Both are pinned.

`smoke-wsgi-stream` is the guard: time-to-first-piece against a 600 ms
body, the hand-decoded chunked probe plus a second request on the same
connection, HTTP/1.0 close-delimited, `write()` inside the generator in
order, honest truncation on a raise, 16 concurrent 1 MB bodies byte-exact,
five abandoned never-ending streams on a four-thread pool, SIGTERM with a
live stream in under a second and with a sleeping generator named as the
straggler, `wsgiref.validate` on a pool, and Django's
`StreamingHttpResponse` reused connection and all.

Recorded follow-ups, not built: an iterator that carries its own
`Content-Length` (`FileResponse`) still buffers rather than streaming
with its declared length — identity framing for both producers; a framed
stream ignores the request's `Connection: close` at its end (pre-existing,
both producers); and the loop handler's frame dispatch is covered end to
end by the smoke rather than by a unit test, because it needs a
`WSGIApp` to construct.
