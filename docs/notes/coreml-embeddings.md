# MiniLM on the Neural Engine, served — measured 2026-09-04

*M4 (4P+6E), macOS 26.6.1, coremltools 9.0, m0serve 0.17.1 (portable
`apple-m1` build), uvicorn 0.52.4 with uvloop and `--interface wsgi`. Every
row is one sequential run on an idle machine, driven one configuration at a
time. The app and harness are [bench/embed_coreml](../../bench/embed_coreml);
the engine is `@qkstat/embed`'s Core ML backend in mojo-addon-examples.*

## The question

[The desktop-Mac note](desktop-mac-server.md) asked whether there is a
reason to run this server on a Mac rather than in a container. The
Apple Silicon design note (`ideas/m0serve-apple-silicon.md`) narrowed it to
fixed-shape encoders on the Neural Engine, and its experiment E4 found
that `MLModel.predict` holds the GIL for its duration — so the question
for m0serve is how it serves a view that never releases the GIL and
answers in half a millisecond.

## What was served

`POST /embed` with one 10-token sentence, answered with a 384-float
embedding: HF `tokenizers` from a file, one Core ML predict on the engine
(0.48 ms in process), JSON out. The same WSGI callable under both servers,
the same interpreter (Python 3.13) for every row. `--doctor` reported
`apple_target: m1`, `performance_cpus: 4`, `protocol: wsgi`.

`wrk -t4 -c8 -d15s`:

| Server | processes | backend | req/s | p50 ms | p99 ms |
|---|---:|---|---:|---:|---:|
| m0serve `--workers 1 --blocking-threads 2` | 1 | engine | **1684** | 4.73 | **5.29** |
| m0serve `--workers 1 --blocking-threads 1` | 1 | engine | 1680 | 4.74 | 5.11 |
| m0serve `--workers 1`, zero-config pool (8 threads) | 1 | engine | 1159 | 7.07 | 15.75 |
| uvicorn `--workers 1` | 1 | engine | 1444 | 5.54 | 9.47 |
| uvicorn `--workers 2` | 2 | engine | 2586 | 3.08 | 4.73 |
| m0serve `--workers 1 --blocking-threads 2` | 1 | MAX, CPU | 727 | 10.91 | 13.14 |
| uvicorn `--workers 1` | 1 | MAX, CPU | 438 | 18.14 | 23.15 |
| uvicorn `--workers 2` | 2 | MAX, CPU | 446 | 17.86 | 24.54 |
| two `m0serve --workers 1` on one port | 2 | engine | 1694 | 4.71 | 4.98 |

At 32 connections: m0serve 1690 req/s at p99 19.5 ms, uvicorn's two
workers 2647 at 19.6. With 8 sentences per request: 5518 sentences/s
against 9569.

## What the table says

- **Process for process, m0serve serves this view 17% faster at 44% lower
  p99.** Predict holds the GIL, so one process is one predict at a time and
  the server's own overhead is the whole difference between the two
  single-process rows.
- **Handler threads do nothing for a view that never releases the GIL**, and
  the zero-config eight cost 31% of the throughput and tripled p99 — the
  hand-off barrier (`_yield_turn`) doing its job on eight threads that can
  never overlap. Pass `--blocking-threads 1` or `2` explicitly for such a
  view. This is not a reason to change the zero-config default, which was
  sized for views that block.
- **A second process is worth 1.5x, and only uvicorn gets it.** See below.

## Three things m0serve's prefork cannot do here

1. **Core ML cannot run in a forked child.** `--workers 2` died 3 of 3:
   the Objective-C runtime refuses (`+[NSPlaceholderString initialize] may
   have been in progress in another thread when fork() was called`), and
   with `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` the model load segfaults
   in CoreServices' libdispatch, the crash report saying "crashed on child
   side of fork pre-exec". This is CLAUDE.md's rule — after `fork()`
   without `exec`, platform runtimes are off limits — met by a runtime the
   application cannot avoid. uvicorn's workers are spawned, so it is
   unaffected.
2. **The tokenizer's download path dies the same way**, earlier and more
   confusingly: `tokenizers.Tokenizer.from_pretrained` resolves proxies
   through `_scproxy`, and the worker is SIGKILLed with the supervisor
   respawning it. The app loads the tokenizer from a file.
3. **Two independent processes on one port do not share the load on
   macOS.** `SO_REUSEPORT` handed all 200 warm connections to one pid, and
   the throughput equalled one process. The Linux workaround is not one
   here.

The feature this asks for is a **spawn-based worker mode**: the supervisor
binds the listener and `posix_spawn`s workers that inherit it, each
initialising Python fresh. It buys the measured 1.5x on this app and
retires the after-fork class of crashes for every macOS application, not
just this one.

## Also found on the way, in the engine's own runtime

Recorded here because a server is where they show and a notebook is where
they hide:

- **Core ML releases each numpy input off-thread, without the GIL**, from
  `MLE5ExecutionStream.resetQueue` a few seconds after the stream idles. A
  server that warms up and then waits died with SIGSEGV every time, on
  coremltools 9.0 and 9.1.dev1 alike; a script that exits promptly never
  sees it. The backend keeps persistent input buffers per shape and fills
  them in place, which leaves one non-atomic off-thread decrement it cannot
  remove.
- **HF BERT's additive attention mask is -inf in fp16**, and the engine
  (which saturates rather than producing NaN) returned embeddings with
  cosine 0.26–0.55 against PyTorch, with an all-ones mask too. A
  timing-only experiment cannot see this. `-1e4` fixes it.
