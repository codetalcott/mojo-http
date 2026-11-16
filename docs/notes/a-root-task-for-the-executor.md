# A root task for the executor — 2026-11-16

> A design note from the engineering record. SPEC L37 names the capability.
> It closes the FastHTML row's gap against uvicorn, on the page since
> 2026-08-27 and read until now as the executor idling between handoffs.

Under m0serve every request that reached Starlette's thread pool started a
thread and ended it. The pool is anyio's, anyio ends a thread with the task
it calls the root, and the executor's loop had no task anyio could find.
The executor's serving run is now one `run_until_complete`.

## The gap

`apps/fasthtml_demo` at `/`, `scripts/bench_asgi_wrk.sh`
(`wrk -t2 -c16 -d8s`, browser headers, three rounds, uvicorn re-measured
every round), macOS 27 on an M4, the tree's locked environment:
python-fasthtml 0.14.19, Starlette 1.6.0, anyio 4.14.2, uvicorn 0.52.4,
uvloop 0.22.1, CPython 3.14.7. Medians, before the change:

| | rps | p99 | cores |
|---|---:|---:|---:|
| m0serve | 4,660 | 6.91 ms | 0.78 |
| m0serve, `M0_INVERTED=1` | 4,541 | 5.79 ms | 0.73 |
| uvicorn asyncio | 4,900 | 4.51 ms | 1.02 |
| uvicorn uvloop | 5,636 | 4.00 ms | 1.01 |

m0serve was at 0.83x uvicorn with uvloop and idle a quarter of a core while
sixteen connections waited. The old reading blamed the wake between the
loop's thread and the executor's. The inverted mode has one thread and no
wake, and idled the same.

## Where it was

Each step removed a suspect:

- The same page from an `async def` handler: m0serve 6,177 rps at 1.05
  cores against uvicorn-uvloop's 5,663. From a `def` handler, 4,624 against
  5,533. The hop to the thread pool cost uvicorn 2% and m0serve 25%.
- A bare ASGI application answering from `anyio.to_thread.run_sync`, with
  no work in the thread: m0serve 16,321, uvicorn asyncio 20,333, uvicorn
  uvloop 31,066. So not FastHTML.
- A GIL switch interval of 100 us, `M0_QOS=1`, and the inverted mode each
  left that row where it was.
- `sample`, four seconds under that load: `__bsdthread_create`,
  `_pthread_create` and `__munmap` among m0serve's top frames, and none of
  them in uvicorn's.

## Why

`anyio._backends._asyncio.find_root_task`, as anyio 4.14.2 has it, looks
for a task whose done-callbacks include the one `run_until_complete`
leaves (`_run_until_complete_cb`, or a callback from `uvloop.loop`). uvicorn
serves from `run_until_complete(serve())`, so it has one for its life.
Finding none, anyio takes the calling task, or the top of its own task
tree. `run_sync_in_worker_thread` then binds a new worker to that task:

```python
root_task.add_done_callback(worker.stop, context=contextvars.Context())
```

The executor thread parked in `_loop.run_forever()`. The root was the
request's own task, the request ended, and its thread was told to stop.

Django's ASGI handler was never affected: asgiref keeps its own
`ThreadPoolExecutor`. That is why the Django row beside the FastHTML one
read 1.18x on the same day. `asyncio.to_thread` uses the loop's executor
and has no such rule: 42,615 rps before the change and 43,236 after, one
five-second run each.

## The change

`_serve_under_a_root_task` in the shim: the serving run is
`_loop.run_until_complete(_until_stopped())`, a coroutine that awaits one
future. `_finish_and_stop` and `_drain_and_stop` called `_loop.stop()`;
they call `_stop_serving`, which resolves the future. The root task ends,
the threads anyio bound to it are told to stop, and the loop stops an
iteration later. Both callers have set `_exec_closed` by then, so nothing
in that iteration reaches the port.

The rule is anyio's and is private. Nothing here reads it: the shim does
what uvicorn does, and the gates below fail if anyio stops recognising it.

## What holds it

- `smoke-fasthtml` and `smoke-fastapi`: twenty requests to a `def` handler
  that counts the requests its own thread has served. Every answer was 1
  on the tree before; one above 1 passes.
- `poe test-shim`,
  `test_the_serving_run_keeps_a_thread_pools_threads`: two tasks, one after
  the other, each asking `anyio.to_thread` which thread it got. Its
  sabotage puts `_loop.run_forever()` back and the test fails.

## After

The same script and machine, the tree with the change and uncommitted
documentation, so a run for this note and not the recorded artifact, which
is the row on [WSGI and ASGI performance](../WSGI_PERFORMANCE.md):

| | rps | p99 | cores |
|---|---:|---:|---:|
| m0serve | 5,764 | 3.91 ms | 1.06 |
| m0serve, `M0_INVERTED=1` | 5,447 | 4.30 ms | 0.99 |
| uvicorn uvloop, beside the default run | 5,504 | 4.05 ms | 1.01 |
| uvicorn uvloop, beside the inverted run | 5,610 | 3.76 ms | 1.01 |

1.05x uvicorn with uvloop by default, with the lower p99. Inverted, 0.97x
with a p99 1.14x uvicorn's: from 0.81x, and still behind.

The bare application, which makes no thread-pool call, did not move:
134,388 rps before and 134,289 after, the medians of five rounds and of
seven. One of the seven read 94,943 at 1.35 cores and no other did.

The bare thread-pool hop went from 16,119 rps to 37,944, against
uvicorn-uvloop's 32,477.

## Not measured

Linux. Throughput for FastAPI's `def` endpoints, which the smoke gates
but no bench measures. `FileResponse`, `StaticFiles` and a synchronous
streaming iterator, which use the same pool by reading and have no gate
of their own. An application that keeps a connection per
thread: by the mechanism it was rebuilt per request, and none was checked.
