"""`--doctor`: what this configuration would do, as JSON, starting nothing.

The launch checklist calls for a machine-readable startup diagnostic, and
the reason is narrower than "nice to have": every refusal this server makes
is already a one-line message that names its fix, but a caller has to
*attempt the run* to see one — and attempting the run binds a port, forks,
and imports the application. An agent choosing flags, or a human debugging
a container that exits 78 in a log it cannot scroll, wants the verdict
without the side effects.

So the contract is deliberately small and total:

    m0serve --doctor [OPTIONS] [MODULE[:ATTR]]

prints one JSON object and exits with **the code `m0serve` itself would
exit with for the same arguments** — 0 when it would serve, 2 for a usage
conflict, 1 when the application cannot be loaded, 78 when the interpreter
cannot run the requested mode. That equivalence is the whole value; a
diagnostic that reports "fine" where the server refuses is worse than no
diagnostic, which is why `checks` below is assembled from the same
predicates `main` branches on rather than from a second description of
them.

This module is the pure half: it holds facts and renders them. Everything
that touches the interpreter, the filesystem or the application lives in
`m0serve.mojo`, which gathers and calls `add_*`. That split is what keeps
`doctor.mojo` in `test-wsgi`, which runs with no Python at all.

Structure-of-arrays throughout, per the repo's Mojo 1.0 convention: a
`List[Struct]` needs `ImplicitlyCopyable` members and these are Strings.

`Report` itself is `m0_http.doctor`'s since 2026-09-19, because a Mojo
host app has a doctor of the same shape (`m0_host`); it is re-exported
here so nothing that imports `m0_wsgi.doctor` changes.
"""

from m0_http.doctor import Report, DOCTOR_OK
