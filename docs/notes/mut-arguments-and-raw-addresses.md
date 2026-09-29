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

Not swept: every other `mut self` of a small address-reached struct against
every re-entrant or concurrent path that could write it, and M3 for the
large ones. The event loop holds `LoopState` and the handler as `noalias`
across handler calls, and under the inverted executor a handler call can
reach the port, which runs passes of its own. Whether to sweep
those site by site, or to change the shape so that a copy-back cannot lose
anything, is an open decision. One such shape is a struct reached by
address whose inline fields never change after construction, with its
mutable state behind a pointer.

## The rule meanwhile

Never hold a struct as a `mut`, `ref` or read-only argument across a call
during which something may write it by address. Resolve it by address in
the frame that uses it (`ref st = Pointer[T, MutUntrackedOrigin](unsafe_from_address=addr)[]`),
pass the address rather than the struct, and read it again after any call
that can re-enter. `ExecutorState`'s docstring states it for the executor.

M2 adds one case the address does not cure: the frame that OWNS such a
struct as a local, and computed its `Int`, reads a stale value after a
`tail` call even through that `Int`. The owner either lets the struct
live on the heap or reads it back only after calls that also pass a
pointer into its frame.

Rerun the matrix after a toolchain move:

```sh
uv run --no-sync python scripts/probes/mut_copyback_matrix.py --evidence
```
