# A `mut` argument is not a reference — 2026-09-29

B20 (PR #463) lost two writes the same way. `_flush_inverted` and
`dispatch_job` took the asyncio executor's `ExecutorState` as a `mut`
argument, code re-entered during the call wrote to that struct through its
address, and when the call returned the caller stored the callee's copy over
the struct. One lost write left an inverted m0serve that never exited on
SIGTERM; the other left unanswered every request that an eager task
answered in its first step. This is the rule behind it, measured on the
pinned toolchain, and how far it reaches in this tree.

## The measurement

`scripts/probes/mut_copyback_matrix.py` generates a matrix of small
programs. In every case a call writes `b = 42` into a struct through the
struct's address, and the program reads `b` after the call. The script
runs the optimized binary and reads each function's signature in the
unoptimized LLVM IR (`mojo build --emit llvm`: KGEN's output, before
LLVM's own passes). Three mechanisms lose the write.

**M1: a `mut` argument of 256 bytes or less is passed by value and stored
back.** The callee takes the struct as an aggregate and returns it, and the
caller brackets the call with a load of the whole struct and a store of the
result:

```llvm
%18 = load { i64, i64 }, ptr %15, align 8
%19 = tail call { i64, i64 } @"matrix::free_Word2(matrix::Word2,::SIMD[DType.int, 1])"({ i64, i64 } %18, i64 %14)
store { i64, i64 } %19, ptr %15, align 8
```

Any write made through the address during the call is erased, whichever
field it touched. The matrix puts the struct on the heap behind an address
that comes from an opaque call, so M2 below cannot be what loses it:

| argument | 256 B or less | over 256 B |
|---|---|---|
| `mut`, `mut self` included | by value and returned: lost | `ptr noalias`: kept, but see M3 |
| `ref` | by value and returned: lost | `ptr`: kept |
| read-only | by value: the callee reads a copy taken before the write | `ptr`: kept |
| `Pointer[T, MutUntrackedOrigin]` | `ptr`: kept | `ptr`: kept |

The threshold is the struct's size in bytes: 256 bytes go by value and 257
by pointer, measured with byte arrays and with word fields. Nothing else in
the matrix moves it. A free function and a `mut self` method behave
alike, as do raising and non-raising, generic and concrete,
`TrivialRegisterPassable` and not, and fields that are `List`, `String` or
pointers. Two things avoid the copy: an `@always_inline` callee, and a
callee that hands out the argument's own address (`Pointer(to=s)`
escaping), which gets `ptr noalias` instead.

**M2: a stack local reached through an `Int` is invisible across a `tail`
call.** KGEN emits a call as `tail call` when, as far as its own origin
tracking can tell, no argument refers to the caller's frame, and an `Int`
address refers to nothing it can track. An LLVM `tail` call promises the
callee touches none of the caller's stack slots, so a local whose address
the frame handed out as an `Int` is assumed unchanged: after the call the
optimizer reuses the value the frame last stored, whether the local is
read by name or back through the same `Int`:

| case | the call | result |
|---|---|---|
| a local, read by name after the call | `tail call` | lost |
| a local, read back through the `Int` address | `tail call` | lost |
| the same, with one more argument pointing into the frame | `call` | kept |
| a heap object reached only by address | `tail call` | kept |

**M3: a `mut` argument over 256 bytes is `noalias`.** Nothing is copied
back, so a field the callee never touches keeps a write made through the
address. The callee's own accesses are another matter:

| case | result |
|---|---|
| the callee reads `b`, a call writes it by address, the callee reads it again | the first value, reused |
| the callee stores `a = 7`, a call reads it by address, the callee stores `a = 9` | the call saw `0` |
| the call writes `b`, which the callee never touches | kept |

All three are optimizations. At `-O0` every argument is a `ptr noalias` and
every write is kept; from `-O1` up the tables above hold. `mojo run`
optimizes by default, so a unit test sees what the built binary does.

## How far it reaches in m0serve

`--census` lists every function in a program's unoptimized IR that takes a
struct by value and returns it. That is M1's shape, and an upper bound on
it, since a function taking a value as `var` and returning the same type
has the shape too. m0serve has 458 such arguments, most of them stdlib
containers (`List`, `String`, `Dict`). The tree's own include:

- every event-loop function that takes the backend as `mut`: 35 of them,
  from `run_pass_once` and `_run_pass` through the accept, request,
  response, stream, timer and shutdown modules. `KqueueBackend` is 24
  bytes, and `EpollBackend` is four word-sized fields;
- six `mut self` methods of `ExecutorPort` (56 bytes): `_dispatch`,
  `_flush`, `_flush_inverted`, `_pass_with`, `_drain_step_with` and
  `_place_frame_with`. B20's fix left `_flush_inverted` taking the port
  itself that way; see below for why that is harmless;
- `SSERegistry`'s five mutators, `AcceptShare`'s four, `WorkerSupervisor`,
  `ProvisionPool`, `WSState`, `ThreadSet.join_within`,
  `DetachingBackend.wait`, and `_deliver`'s `PgListenSpec`.

The struct types the tree reaches through a raw address fall on both sides
of the threshold:

| 256 B or less: M1 | over 256 B: M3 |
|---|---|
| `ExecutorState` 168, `ExecutorPort` 56, `ThreadedServer` 200, `HostContext` 248, `PgListenSpec` 80, `MojoPool` 88, `KqueueBackend` 24, `ThreadSet` 24, `AcceptShare` 96 | `OffloadPool` 584, `LoopState` 1136, `WSGIHandler` 808, `ServeOptions` 544, `LoopShared` 488, `WSGIApp` 296, `PyBridge` 288 |

Sizes are `size_of` on macOS arm64.

## What was checked

A copy-back loses nothing when nothing writes the struct during the call.
These were read against the source:

- **`ExecutorPort`**: every field is set in `__init__` and never again, so
  each copy-back stores what was already there.
- **The backend**: its one inline field that changes is `_n_ready`, which
  `wait` sets and the same pass reads. The event buffer and the timer table
  live behind pointers.
- **`PgListenSpec`**: read-only after construction.
- **`_place_frame_with`**, which B20 left unchanged, holds the
  `OffloadPool` as `ptr noalias` (M3) across the passes it runs, and reads
  only `stream_chunk_write` from it, a descriptor fixed at setup. No write
  can be lost there, so it is unchanged.
- **`_executor_serve`** reads `state.pending_done` by name after
  `run_forever`, which is M2's shape. In m0serve's IR that call is a plain
  `call`, not a `tail call`, so the read is fresh. That rests on how KGEN
  marks the call rather than on anything the source says.

The rest of the census, M3 for the large types included, was swept after
this: the next section.

## Who writes them: the sweep

A copy loses a write only when something writes the struct while the call
holds it. The sweep (A2) took every type of the tree's own in two
censuses, m0serve's and that of the Mojo host's gate application,
`apps/host_check`, which adds the host's pool, producer and loop threads.
For each it listed the inline fields that change after construction and
looked for a writer of them that can run during the call: another thread,
a signal handler, or code the call re-enters. A field behind a pointer is
out of a copy's reach, since the store-back writes the same pointer back.
A `List`'s header is not: its data pointer, length and capacity are
inline.

| struct | passed | what changes inline, and who writes it during a call | verdict |
|---|---|---|---|
| `ExecutorState` | M1, when taken as `mut` | `stopping`, `drain_start` and the list headers, by the port re-entered from inside its own calls | live: B20's two sites, fixed in #463 and now guarded |
| the backend: `KqueueBackend` 24, `EpollBackend` 32, `DetachingBackend` | M1, in 35 loop functions and `DetachingBackend.wait` | `_n_ready` alone. Under `M0_INVERTED` a pass run inside a pass calls `wait` through the backend's address, and the outer frames store their own count back over it | latent: the count restored is never read before the next `wait` rewrites it |
| `ExecutorPort` 56 | M1, in six methods | nothing: every field is set in `__init__` | safe |
| `AcceptShare` 96 | M1, in five methods | `drained`, `handoffs_in`, `handoffs_out` and `left`, only by its own methods, which call `sendmsg`, `recvmsg` and atomics. Siblings write the shared page, behind `page` | latent |
| `SSERegistry` 104 | M1, in five mutators | four list headers and a count, only by the mutators, which call nothing | latent |
| `WorkerSupervisor` 240 | M1 in three methods, `ptr noalias` in the rest | `child_pids` and the counters, only by the supervisor's own flow. Its signal handler writes global words (`global_slot.mojo`), never the struct | latent |
| `ThreadSet` 24 | M1, in `spawn`, `join_all` and `join_within` | nothing: a count and two `malloc`'d addresses. Its threads write their blocks, behind them | safe |
| `PoolThreads`, `MojoPool` 88, `BlockingPool`, `ProducerThread`, `AsgiExecutor` | M1, in their `deal`, `start` and `stop_and_join`, and `MojoPool` into the host's `_start_pool` and `_join_pool` | `started`, `stragglers` and the lanes, only by the owning thread. Pool, producer and executor threads write `malloc`'d blocks and atomics | latent |
| `ProvisionPool`, `WSState`, `HTTPChunkedDecoder`, `Socket`, `ServerMetrics` | M1 | per-connection state, by callees that call nothing or one syscall | latent |
| `OffloadPool` 584 | M3 | scalars, set before any thread starts or after the loop ends; the `aborts` and `_drain_buf` headers, by the loop thread alone. Pool and executor threads write list elements and ring words, behind pointers | latent |
| `LoopState` 1136, `WSGIHandler` 808, `PyBridge` 288 | M3 | under `M0_INVERTED`, a nested pass writes them by address while outer frames hold them `noalias`: see below | latent, not measured |
| `HostContext` 248, `LoopShared` 488, `ThreadedServer` 200, `ServeOptions` 544, `PgListenSpec` 80, `Ring` 16, the demo mount's `Corpus` | read-only, M1 or M3 | nothing after construction: other threads only read them | safe |

Latent means a mutable inline field that nothing writes during the call
today, or whose lost value nothing reads. Sizes are bytes on macOS arm64.

**The nested pass.** The one path on which code a call re-enters writes a
struct through its address, beyond the executor's own state, is under
`M0_INVERTED`. An eager task's first step runs inside
`WSGIHandler.direct_job`, and a frame it places through `_place_frame_with`
can run a pass inside the pass. Review record B23 takes that path on for
its own sake, since the inner pass overwrites the event buffer the outer
one is reading, whatever the compiler does. The compiler's share of it:

- M1: the outer frames hold the backend by value and store back only
  `_n_ready`, a dead value. A field added to the backend or to
  `ExecutorPort` for this path would be restored the same way: state a
  nested call must see belongs in `ExecutorState`, reached by address.
- M3: `_process_request` holds `LoopState` as `noalias` across
  `handler.direct_job(slot)`, which receives no pointer to it. It adds to
  `st.offload.inflight` before the call and returns after it, so nothing is
  read stale; a store the optimizer moved past the call would overwrite
  what the nested pass wrote there. Whether it moves one was not measured.
- M3: `spawn_asgi` holds `PyBridge` as `noalias` across the Python call in
  which the first step runs. A nested `spawn_asgi` rewrites the bridge's
  two scratch lists, which the outer call uses only before that call.

**M2.** A scan of both programs' IR for M2's shape (a local whose address
escapes into memory, then a `tail call`, then a load or store of the local)
finds six sites, all in `_executor_serve` and `serve_inverted`, and every
tail call among them is one of `OffloadPool`'s descriptor getters, which
write nothing. `run_forever` and `run_forever_inverted`, during which the
port writes those locals, are called on a sub-object of a local, a pointer
into the frame, so neither is a `tail call`.

**C callbacks.** m0-sqlite's virtual-table callbacks read and write only
`malloc`'d words (the vtab, the cursor and the stored entry points), and
m0-postgres polls `PQnotifies`, so libpq calls back into nothing.

**On Linux.** The matrix in the Linux container (aarch64, the same Mojo
1.1.0 build) prints the tables above cell for cell: the 256-byte threshold
and all three mechanisms. The census of m0serve's Linux IR counts 459
arguments to macOS's 458, with the same types of the tree's own:
`EpollBackend`, in six functions, in place of `KqueueBackend`, in five.

## The guard

`poe check-copyback` (`scripts/copyback_guard.py`, SPEC L31, in `test-all`)
fails when a listed type is passed by value anywhere in m0serve's IR,
emitted with `build-serve`'s flags. The list holds one type,
`ExecutorState`, the only one the sweep found written by address while a
call holds it. A type belongs on it once that is true of it.

- It matches a type by its layout, read from the type's own constructor,
  not by the name the census prints. KGEN appends a raising function's
  error slot to its parameters, and the census printed the type of B20's
  `_flush_inverted(mut self, mut st)` as `?`. The census now names such a
  function's parameters from the start, which leaves `?` for a symbol one
  of whose zero-sized arguments KGEN dropped.
- It flags a copy whether it is returned (M1) or not (a read-only copy,
  stale for the same reason), and a layout held inline by another
  argument's, whatever that argument is called.
- It shows it can fail on every run. A control program takes the type in
  B20's two shapes and inside a copied struct, and all three copies must be
  seen. When they are not (the census is blind, or the type has grown past
  256 bytes, onto M3's side, which this cannot see), it stops with 2. A
  `--selftest` over canned IR holds the judgement itself.

Sabotaged in a copy of `m0-wsgi/src`, precompiled beside a copy of the
entry file: `mut st` put back in `_flush_inverted` fails it, naming that
function, and put back in `dispatch_job`, naming the body it delegates to;
an `ExecutorState` inside a struct taken `mut` fails it too; the unsabotaged
copy passes. The copied entry file matters. Its own directory is searched
before any `-I`, so a sabotaged `.mojoc` elsewhere on the path is ignored
without a word, and the first attempt judged the real one and passed.

Both IRs compile in 7 s on an M4, and in 12 s in the Linux container.

## The rule meanwhile

Never hold a struct as a `mut`, `ref` or read-only argument across a call
during which something may write it by address. Resolve it by address in
the frame that uses it (`ref st = Pointer[T, MutUntrackedOrigin](unsafe_from_address=addr)[]`),
pass the address rather than the struct, and read it again after any call
that can re-enter. `ExecutorState`'s docstring states it for the executor,
and `poe check-copyback` holds it there.

M2 adds one case the address does not cure: the frame that OWNS such a
struct as a local, and computed its `Int`, reads a stale value after a
`tail` call even through that `Int`. The owner either lets the struct
live on the heap or reads it back only after calls that also pass a
pointer into its frame.

Rerun the matrix after a toolchain move:

```sh
uv run --no-sync python scripts/probes/mut_copyback_matrix.py --evidence
```
