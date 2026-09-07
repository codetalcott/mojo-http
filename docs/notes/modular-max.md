# Modular MAX: license and relevance — researched 2026-09-07

*Desk research against modular.com, docs.modular.com and the
modular/modular repository as of this date, plus this repo's one prior
measured contact with MAX. Licensing summaries here are a reading, not
advice; the license texts govern.*

## The question

Should this server be extended or improved via MAX? Short answer: the
HTTP server gains nothing from MAX itself, and MAX should stay out of
the dependency tree — but MAX-backed *applications* are exactly the
workload this server already serves well, and one bounded exploration
(a portable embeddings app) is worth having. The materially good news
of 2026 is about Mojo's license, not MAX's capabilities.

## What MAX is

The Modular Platform (MAX) has three parts:

- **Serving** — an OpenAI-compatible inference server (`max serve`) for
  LLMs and embedding models (`v1/embeddings` included), on NVIDIA, AMD
  and Apple GPUs and, since ModCon 2026, AWS Trainium, Google TPUs and
  Qualcomm accelerators.
- **Modeling** — a PyTorch-like Python graph API and `InferenceSession`
  for loading weights and building custom pipelines in Python.
- **Kernels** — the accelerator library at `/max/kernels` in
  modular/modular: hundreds of Mojo kernels, one codebase per kernel
  across vendors.

## Licensing, as it stands September 2026

- **Mojo is fully open source.** With Mojo 1.0 (August 2026, after
  Qualcomm's acquisition of Modular closed), the entire language —
  compiler and tooling included — is Apache 2.0 with LLVM exceptions.
  The exceptions matter here: binaries compiled from Mojo carry no
  attribution obligation, so shipping `bin/m0serve` and the wheel is
  unencumbered. This repo's `mojo==1.0.0` dependency is license-clean
  for an MIT project.
- **The modular/modular repository source is Apache 2.0 with LLVM
  exceptions**, `/max/kernels` included.
- **MAX usage and distribution stay under the Modular Community
  License.** ModCon 2026 removed the device-count restriction
  (previously 8 non-x86/ARM/NVIDIA accelerators) and announced a
  transition to source-available with an "open alliance" program.
  What remains: development and production use are broadly permitted;
  derivative works owe an attribution string; an application
  redistributing MAX components must add "material additional
  functionality"; commercial hosted AI services owe trademark
  compliance; and MAX may not be used as training or fine-tuning data
  to produce a substitute for it (building *interoperable* software is
  expressly permitted).

So: depending on MAX at runtime is fine, embedding it in a product is
fine with attribution, and none of it touches this repo today, because
nothing in `packages/` or `apps/` imports MAX — `pyproject.toml` says
so deliberately, and this note is a reason to keep it that way rather
than a reason to change it.

## Prior contact, measured

[MiniLM on the Neural Engine](coreml-embeddings.md) already put a
MAX-backed embeddings view behind this server (2026-09-04): MAX on CPU
served 727 req/s under `m0serve --blocking-threads 2` against 438–446
under uvicorn — the same view, 1.6x — while the Core ML engine on the
same machine did 1684. Two readings worth keeping:

- MAX's Python inference path is a GIL-holding, CPU-heavy view — the
  workload the handler pool's turn-taking was built for — and the
  measured gap over uvicorn was *larger* on the MAX rows than on the
  Core ML rows. MAX apps are a favorable workload for this server, not
  the other way around.
- Unlike Core ML, MAX has no Objective-C runtime in the request path,
  so it does not join the after-fork crash class that forced
  `--spawn-workers` — and it runs on Linux, where CI is.

## What is worth exploring, and what is not

Worth it, in order:

1. **A portable embeddings example or bench app** (`InferenceSession`
   on CPU/GPU behind a WSGI or ASGI view). It would be the one
   inference example that runs on Linux CI hardware, exercises the pool
   and the executor with a real GIL-holding model, and gives the
   coreml note a portable comparator. Scope: an app and a bench
   harness, never a dependency of `packages/`.
2. **`max serve` as a sidecar, proxied.** LLM token streams are
   hold-shaped: a demo where a sync view approves an SSE hold and the
   app relays a sidecar's OpenAI-compatible stream through
   `m0pub.publish()` would exercise `--realtime` against a real
   producer. Demo-shaped, not a feature.
3. **`/max/kernels` as reading material.** Apache 2.0 Mojo at
   production quality — SIMD, memory and dispatch idioms on the pinned
   language version. Borrowed code would need its Apache notice
   recorded, as NOTICE already does for the fork.
4. **Upstream leverage.** The toolchain issue this repo tracks
   (modular/modular#5726, the `PythonModuleBuilder` object-header
   mismatch behind the ASGI free-threading refusal) now lives in a
   fully open repo; watching it — or fixing it — is more tractable
   than it was.

Not worth it:

- **MAX in the HTTP path.** MAX is inference infrastructure; it offers
  nothing to parsing, the event loop, or the WSGI/ASGI seam.
- **MAX as a package dependency.** It would put the Community License
  and a large install into every consumer's tree for something no
  package imports.
- **Competing with `max serve`.** Model serving is its whole product;
  this server's role beside it is the application tier and the
  streaming edge, which is the sidecar shape above.
