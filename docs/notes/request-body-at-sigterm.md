# A request body still arriving at SIGTERM held the drain to its deadline — resolved

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

The drain loop read nothing new, so a half-received upload was neither
completed nor closed until the 5 s budget expired: the client was reset
and the process exited at 5.09 s. Found by the soak driver's uploads
population on color-separation, reproduced bare by
`scripts/drain_upload_probe.py`, fixed by running ordinary loop passes
during the drain (see "The drain does not read a request body in flight"
above). Gated by D9, every PR, in both execution shapes.
