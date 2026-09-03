# The drain does not read a request body in flight — resolved

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

Found by the soak driver's uploads population on color-separation
(2026-09-02): with 9.7 MB multipart uploads in flight, every SIGTERM drain
took exactly its 5 s budget, and the bisection put it on uploads alone.
Measured directly with `scripts/drain_upload_probe.py`: a 10 MB POST with
5 MB delivered when SIGTERM lands and the rest sent a second later was
never read — `_run_shutdown`'s loop dispatched `EVFILT_WRITE` only, by
design ("nothing new is read during the drain") — so the client was reset
at 5.03 s and the process exited at 5.09 s. Half of `docker stop`'s
patience spent on a request that would have completed in milliseconds;
gunicorn's graceful timeout keeps reading. The request-side twin of the
response-side defect `drain_inflight_probe.py` pins: that one held the
drain for a connection already *answered*, this one for a request not yet
*received*. The same write-only loop had a second consequence nothing had
measured: a response too large for one `send` was cut at its first write
readiness, because that branch closed the slot instead of sending the
rest.

**The fix is to stop re-implementing the loop.** The drain now runs
ordinary `_run_pass` passes for its budget: mid-request bodies are read,
responses are written whole, pool completions and bus frames are
serviced, buffered submits flushed. The listener is already closed so a
pass accepts nothing, and `_close_between_requests` after every pass is
what bounds it: a connection with no request in progress is closed, so
only bytes the client had already sent are ever served. The shutdown pipe
is deregistered first — its byte is never read, so a registered pipe
stays readable and every pass would break at it. Gated by SPEC D9
(`smoke-drain-upload`, both shapes, two-sided); sabotaged by restoring the
old loop, which the probe reports as the reset at 5.03 s and the exit at
5.09 s. Measured after: answered whole and exited at 1.08 s, the extra
second being the probe's own delay before sending the rest of the body.
