# The host

`m0_host` is what a Mojo application's `main` calls. It owns the listener,
the workers, the signals and the drain; the application supplies a handler
and, if it has work on a cadence, a producer.

```mojo
from m0_host.flags import host_config
from m0_host.host import ViewsApp, serve

from views import Items

def main() raises:
    serve[ViewsApp[Items]](host_config())
```

## What an application supplies

`serve[H, P](config)` takes two types.

**`H: AppHandler`** is an `HTTPService` with a static `make(ctx)`. The host
calls `make` once per worker, after the fork, so each worker builds its own
handler. Three more static methods have defaults:

| method | default | what it declares |
|---|---|---|
| `page_slots(workers) -> Int` | 0 | words of shared memory, created before the fork and handed to every `make` as `ctx.page` |
| `max_workers() -> Int` | 0, any number | the most processes this application serves from |
| `max_threads() -> Int` | `max_workers()` | the most loops in one process |

An application whose state lives in the handler answers `max_workers() -> 1`.
`M0_WORKERS=2` is then refused at startup: two workers would hold two
different copies.

**`ViewsApp[S]`** is the `AppHandler` for an application that is a
[views table](MOJO_VIEWS.md). `S: ViewState` has `make(ctx)` and `urls()`,
and the same three optional methods. Both scaffolds use it.

**`P: Producer`** is work on a cadence, off the event loop: `make(ctx)`, and
`step(mut self, mut out: Publisher) -> Int`, which returns the nanoseconds
until the next step. One producer runs, on a thread of worker 0, and
`out.publish(channel, id, frame)` reaches every worker's streams. Number
frames with `out.next_id()`: the counter is shared memory, so it survives a
worker being replaced. `publish` returns `False` for a frame a channel
refused; count those. `NoProducer` is the default.

`HostContext`, the argument to every `make`:

| field | meaning |
|---|---|
| `worker`, `workers` | this worker's index and the count; processes or loops |
| `threaded` | whether the workers are loops on threads of one process |
| `thread` | -1 for the loop's own handler, 0 upward for a pool thread's |
| `capacity` | the connection capacity; a stream registry needs at least this many slots |
| `page` | address of the application's shared page, or 0 |
| `bus` | every worker's channel, for a handler that publishes to its peers |
| `config` | the resolved configuration |

A `make` that raises, in a handler or a producer, ends the process with
exit 78 and its message. It is not retried.

## Execution modes

One loop in one process is the default, and on one vCPU it is the whole
answer ([Deploy](MOJO_DEPLOY.md)).

**`M0_THREADS=N`** runs N loops on N threads of one process, and is the
way to more than one core. Nothing is forked, so a runtime that cannot
survive a fork works — MAX's parallel runtime, Core ML, CoreFoundation —
and the loops share an address space. There is no supervisor: a loop that
dies takes the process, and the platform restarts it. Refused beside
`M0_WORKERS` above 1.

**`M0_WORKERS=N`** forks N processes that share the listener. A worker that
dies is replaced. The worker that wins an accept hands the connection to
the least-loaded sibling, so keep-alive load spreads. Refused when the
binary links MAX's parallel runtime (`libAsyncRTMojoBindings`, what
`max.algorithm.parallelize` needs): `fork()` copies the calling thread
alone, and a `parallelize` in a forked worker never returns. On macOS a
binary built beside an installed `max-core` links that runtime whether
or not it imports MAX, so there the refusal covers every build in a MAX
venv ([known issues](ROADMAP.md#known-issues)).

<!-- observed: docs/notes/loops-on-threads.md, from bench/results/host-modes-20260918T201017Z.json (macOS, M4, four loops) and its Linux aarch64 twin -->
Measured against each other, threads and workers are level on throughput
(0.95x to 1.03x) and on the tail, and threads use a fifth to a third less
memory. Workers are for an application that links no MAX and wants a
supervisor. `ctx.worker` and `ctx.workers` count either, so an application
runs under both unchanged.

**`M0_BLOCKING_THREADS=N`** puts N handler threads behind each loop, and
composes with either mode. The loop keeps accepting and parsing while a slow
view runs on a pool thread. Each pool thread builds its own handler with
`make` (`ctx.thread` says which). A view registered with `add_loop`, or
`on_loop=True`, is answered on the loop and never queued. A stream must be
opened on the loop: one begun on a pool thread is refused with 409.

## Configuration

A flag overrides its `M0_` variable, which overrides the default.

| flag | variable | default |
|---|---|---|
| `--host ADDR` | `M0_HOST` | 0.0.0.0 |
| `--port N` | `M0_PORT` | 8080 |
| `--workers N` | `M0_WORKERS` | 1 |
| `--threads N` | `M0_THREADS` | 1 |
| `--blocking-threads N` | `M0_BLOCKING_THREADS` | 0 |
| `--access-log` | `M0_ACCESS_LOG` | off |
| `--sse-heartbeat-ms N` | `M0_SSE_HEARTBEAT_MS` | 15000 |
| `--app-tick-ms N` | `M0_APP_TICK_MS` | 0, off |
| `--max-keepalive-requests N` | `M0_MAX_KEEPALIVE_REQUESTS` | 1000 |
| `--qos` | `M0_QOS` | off; macOS, keeps the loop on performance cores |
| `--spawn-workers` | `M0_SPAWN_WORKERS` | m0serve's; refused here |
| `--doctor` | | print the configuration, start nothing |
| `--help` | | |

`host_config()` is an `AppConfig` with the command line applied, for an
application that prints its own address before serving. `serve(AppConfig())`
applies the flags itself.

## Exit codes and refusals

| code | meaning |
|---|---|
| 0 | served, then drained on SIGTERM or SIGINT |
| 1 | a failure while starting or serving: the address cannot be bound, a loop raised, a loop did not finish its drain |
| 2 | a command line that cannot be read: an unknown flag, a value that is not a number |
| 78 | a configuration that was read and will not be served |

Every 78 is one line on stderr: what was found, then the fix in
parentheses. The checks, in the order the host applies them:

| check | refused when |
|---|---|
| `workers-count` | `M0_WORKERS` is below 1 |
| `workers-vs-application` | `M0_WORKERS` is above the application's `max_workers()` |
| `threads-count` | `M0_THREADS` is below 1 |
| `workers-vs-threads` | `M0_WORKERS` and `M0_THREADS` are both above 1 |
| `threads-vs-application` | `M0_THREADS` is above the application's `max_threads()` |
| `spawn-workers` | `M0_SPAWN_WORKERS` is set: the host forks without exec |
| `spawned-marker` | `M0_WORKER_SPAWNED` is inherited from an m0serve worker |
| `workers-vs-parallel-runtime` | `M0_WORKERS` is above 1 and the binary links MAX's parallel runtime |

A count is refused the same way whether it came from a flag or a variable.

## The doctor

`bin/server --doctor` prints one JSON object as the last line of stdout and
binds nothing. It holds the resolved configuration, where each value came
from (`flag`, `env` or `default`), the topology that adds up to, what the
application declares (`max_workers`, `max_threads`, `page_slots`), and a
`checks` array in which every failure carries its `fix`. The API key is
never printed. It exits with the code serving would exit with for the same
arguments, because `serve` and the doctor read the same list of checks.

`uv run m0 doctor` runs the toolchain's checks first (`platform`,
`mojo-installed`, `mojo-gated`, `max-gated`, `c-compiler`, `project`), then this one.

## Shutdown

SIGTERM and SIGINT drain: in-flight requests finish, held streams are
closed from the server, and the process exits 0. The drain, the handler
pool's join and the producer's join share one five-second bound. A thread
still running after it is named on stderr and the process exits anyway, so
`docker stop` never waits for SIGKILL. The binary runs correctly as PID 1.

The capability rows are E21 to E31 in [Capabilities](SPEC.md). The design is
recorded in [the Mojo host](notes/the-mojo-host.md),
[loops on threads](notes/loops-on-threads.md) and
[flags and a doctor for the host](notes/flags-and-a-doctor-for-the-host.md).
