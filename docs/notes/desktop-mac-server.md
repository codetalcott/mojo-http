# The desktop-Mac server, and what the wheel gives up to ship

> A design note from the engineering record, moved out of ROADMAP.md on
> 2026-09-03 and kept as written. The roadmap itself now holds only the
> project's state; the reasoning lives here.

**The hypothesis** (not yet tested): this server's strongest commercial
position may be as a *desktop* server — a Mac mini or Studio running an
application on hardware someone already owns — rather than as a Linux
container competing with Granian and uvicorn on rps. The reasoning is that
Mojo's reason to exist is compute, and a Mac's compute is unusual: unified
memory, a GPU on the same die, a neural engine, and from M4 the SME/SME2
matrix extension. A server that could reach those from a request handler
would be doing something no Python server can.

**The finding that complicates it, which is concrete and already in the
tree.** `poe build-serve` pins `--target-cpu` to the *oldest* Apple Silicon:

    Darwin-arm64) tcpu=apple-m1 ;;      # oldest Apple Silicon

That pin exists because it had to — the first release crashed with SIGILL
in a clean container, and the comment beside it records that this
developer's machine natively targets `apple-m4` with **+sme/+sme2**, which
no M1/M2/M3 has. So the honest answer to "does the PyPI wheel retain
M-series-specific capability?" is **no, deliberately**. One portable wheel
per platform and per-microarchitecture code generation are the same
tradeoff seen from two sides, and the release path currently takes
portability.

That is not an argument against the hypothesis. It is an argument that
**the current distribution shape and that hypothesis are in tension**, and
that the tension should be resolved deliberately rather than discovered.
The options, none costed yet:

- per-microarchitecture wheels (`apple-m1` / `apple-m4`), selected by
  `pip` — more release matrix, and `pip` has no microarch selector, so it
  would need a launcher or a source path
- runtime dispatch: one binary, feature-detected code paths — the usual
  answer, and the most work
- keep the wheel portable and treat accelerator work as an opt-in
  component built on the target machine

**What has to be established before any of that is worth costing**, because
the whole hypothesis rests on it:

1. **Can Mojo target the Apple GPU at all?** Not assumed either way here.
   This toolchain has no `gpu` module — `from gpu.host import DeviceContext`
   fails with "unable to locate module 'gpu'" — but this repo installs
   `mojo` alone rather than the full MAX package, so that is evidence about
   *our* install, not about Modular's support. Check the MAX documentation
   for Metal/Apple Silicon status before building anything on it.
2. **The neural engine is probably not reachable.** Apple exposes the ANE
   through CoreML and publishes no low-level API; a language targeting it
   directly would be doing something Apple does not document. Treat "tap
   the neural engine" as *via CoreML from Python*, which needs no Mojo at
   all, until shown otherwise.
3. **What would a request handler actually do with it?** The server's hot
   path is HTTP parsing and a CPython crossing; neither is matrix work.
   The win, if it exists, is in *application* code the server hosts — which
   makes this a story about `m0-core`/MAX rather than about the HTTP layer,
   and possibly a different product.
4. **Is the premise even load-bearing?** `has_accelerator()` returns True on
   this M4, but that is one bit and should not be over-read.

Recorded now because the packaging decision that forfeits M-series
capability was made for a good reason, is already shipped, and would
otherwise be invisible to whoever picks this hypothesis up.
