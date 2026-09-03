# A conformance-suite tier

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The server is pinned by hand-written probes against the RFC text -- `smoke-ws`
speaks RFC 6455 from stdlib sockets, `test_parsing.mojo` covers the smuggling
shapes directly -- and by no external suite on any cadence. A parser fuzzer
over the request decoder is the cheap half of this tier: the decoder is
already a pure function over bytes with its own unit suite, so the harness is
small (G13).

**Autobahn|Testsuite was RUN, on 2026-08-30, before deciding to wire it.**
The handoff asked for that deliberately: `fe26113` is the commit before
v0.15.1's fix, a build with a known, fully characterised RFC 6455 §5.5.1
violation, so the suite could be asked whether it catches a bug we already
had. **It does not.** Same pure-echo ASGI app, same client, two builds:

| build | section 7 (close handling), 37 cases |
|---|---|
| `fe26113` pre-fix, known violation | 24 OK, 3 informational, 10 FAILED |
| `f2d098b` post-fix, the shipped fix | 24 OK, 3 informational, 10 FAILED |

Identical case for case: 7.5.1, 7.9.1-7.9.9. The reason is structural, and it
is the useful part of the result: **Autobahn's fuzzing client always
initiates the close itself.** The bug was on the APP-initiated path -- the
server sends Close first and must then wait to receive one -- and no
conformance client can make a server's application close first. That is a
region of RFC 6455 an external suite cannot reach, which is a better argument
for `ws_probe.py`'s close-order phase (64 concurrent app-initiated closes)
than the one written when it was built.

So the earlier claim here -- that "the browsers and `websockets` all publish
517/517, so the bar is unambiguous and the result is comparable" -- was wrong
twice over, and is withdrawn. The comparison is not like for like (6 of the
failures below are a documented cap, not a defect), and a green suite would
not have meant what it was being cited to mean.

It is still worth having, for what it DID find — and one of the two causes
below has since been fixed on the strength of it. **Measured before the fix**,
outside the performance section, it scored **230 of 247**:

| section | cases | OK | non-strict | informational | FAILED |
|---|---|---|---|---|---|
| 1, framing | 16 | 10 | 0 | 0 | 6 |
| 2-5, pings, opcodes, fragmentation | 48 | 41 | 7 | 0 | 0 |
| 6, UTF-8 handling | 145 | 141 | 4 | 0 | 0 |
| 7, close handling | 37 | 24 | 0 | 3 | 10 |
| 10, auto-fragmentation | 1 | 0 | 0 | 0 | 1 |

Sections 12 and 13 are excluded (no `permessage-deflate`, I14). Section 9 is
performance and was sampled rather than run: 9.1.\*/9.2.\* failed 12 of 12,
for the same reason as section 1 below. All 17 failures reduce to two causes:

- **Close codes were echoed, not validated** (10 cases: 7.5.1, 7.9.1-7.9.9).
  A Close carrying 0, 999, 1004, 1005, 1006, 1016, 1100, 2000 or 2999 came
  back with that same code, where RFC 6455 §7.4.1 wants the connection failed
  with 1002 and 7.5.1 wants 1007 for a reason that is not valid UTF-8. The
  contradiction is sharpest at 1006: "abnormal closure" describes the ABSENCE
  of a close frame, so a close frame carrying it cannot be honest, and the
  server answered it with its own 1006. **Fixed** —
  `close_code_is_valid_from_peer` in `websocket.mojo` validates the code and
  the reason's UTF-8 before the echo, and I16 is `verified` on unit tests
  either side of the line (a refusal that refuses everything fails
  `test_legal_close_codes_are_still_echoed`). **Section 7 went 24 OK / 3
  informational / 10 FAILED to 34 / 3 / 0**, with sections 1-6 unmoved.
  Note what this was NOT: text frames validated UTF-8 correctly all along,
  which is what section 6's 145 clean cases say and what I5 already claimed.
- **The 64 KB outbox cap** (7 cases: 1.1.6-1.1.8, 1.2.6-1.2.8, 10.1.1, plus
  all of section 9). `MAX_PENDING_BYTES` bounds one frame as well as the
  queue, so a message at or above 64 KB ends the connection instead of being
  echoed. Deliberate and documented; recorded as I17 so the failures are not
  re-diagnosed as a bug each time the suite is run.

With I16 fixed the score outside the performance section is **240 of 247**,
and **every remaining failure is I17's cap** — which makes the next run of
this suite unusually cheap to read: anything that is not a >=64 KB payload is
new.

**Where it should live, if wired: pre-release, not `Tests`.** It needs Docker
and roughly ten minutes, CI is already ~25 minutes, and its unique value --
close-code validation -- is a defect that will be fixed once rather than a
regression that recurs. `docs/RELEASING.md` beside `stress-asgi` is the fit.
One practical finding for whoever does it: running every section in ONE pass
wedged at case 6.21.6 and never recovered, while the same server ran all 145
of section 6 cleanly when section 6 was run alone. Section 1's >=64 KB cases
end their connections, and the next case lands on the recycled slot; a
single-pass run therefore understates the server, and the harness has to
drive the sections separately.

**Wired, 2026-09-01** (SPEC I13): `poe autobahn` runs
`scripts/autobahn_runner.py` -- sections driven separately as above, 9/12/13
excluded, the image pinned to `25.10.1` (digest-identical to the one the
baseline was measured with, which is what lets the per-section case counts
be asserted exactly). The server is the runner's own pure-echo ASGI app,
because `asgi_bare`'s `/ws` prefix-echoes text for its probe's benefit and
Autobahn's byte-identity cases would score that as failures. The comparison
runs both directions -- a failure outside I17's seven is new and red, and
one of the seven *passing* is red too, the cap having moved out from under
the sheet -- and the comparator's `--selftest` runs before anything is
believed. The wired run reproduced the baseline exactly (226 OK, 11
non-strict, 3 informational, I17's 7 FAILED), and reverting I16's
close-code validation was caught as nine named new failures (7.9.1-7.9.9)
on the first section-7 run.

PortSwigger's desync scanner and h2spec are NOT this tier, and no longer
promise to be: they were one `planned` row (B8) citing this heading, which
contradicted the refusal two sections above it on the same page. They are now
two refusals of their own -- **B8** for h2spec, which needs HTTP/2 (A18, and
C7 refuses downstream of it), and **B9** for the desync scanner, which probes a
proxy/server PAIR for disagreement about framing and so has nothing to compare
against a server with no proxy in front of it. The smuggling rows stay
unit-tested (B1-B7), and fuzzing the decoder itself is the second half of this
tier (G13).
