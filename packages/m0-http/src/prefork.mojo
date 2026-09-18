"""What a prefork server creates before it forks: one module, both hosts.

`m0serve` (the Python host) and `m0_host.host` (the Mojo host) each
need the same three things made before `fork_all()`, because a fork copies
descriptors and shared mappings and nothing made after it reaches a sibling:

- **the shared page** (`prefork_page`): `accept_share_slots(workers)` Int64
  words -- slot 0 the SSE event id every publish numbers from, slot 2
  `SHARED_PAGE_MAGIC`, then each worker's accept-share line;
- **the bus** (`prefork_bus`): one datagram channel per worker, every
  worker holding every send end;
- **the accept-share channels** (`prefork_accept_share`), above one worker
  unless `M0_ACCEPT_SHARE=0`.

Each is also EXPORTED, by descriptor number, so a worker that `exec`s
(`m0serve --spawn-workers`, SPEC E15) -- or a child process an application
starts to publish from (`m0pub`) -- can reach it: `M0_SHARED_ID_FD` and
`M0_SHARED_ID_ADDR`, `M0_BUS_READ_FDS`/`M0_BUS_WRITE_FDS`,
`M0_ACCEPT_READ_FDS`/`M0_ACCEPT_WRITE_FDS`. Those names are m0pub's
interface as much as the server's; they do not change here. Every exported
descriptor goes through `keep_across_exec`, because macOS's `shm_open` and
some socket calls set `FD_CLOEXEC`.

A spawned worker (`spawned_worker_index() >= 0`) creates nothing: each
function ADOPTS what its parent exported, and the page is mapped again,
because a mapping does not survive `exec` and its address in this image is
new -- which is why `M0_SHARED_ID_ADDR` is re-exported there before anything
reads it.

The page is file-backed where the host allows it (`shm_open` needs a
shared-memory filesystem, which a stripped container can lack). Where it
cannot be, a server that execs its workers cannot run at all and the error
stands (`required=True`); anything else serves from the anonymous page,
which every forked worker shares, and says what a child process loses.

Moved down from `m0serve.mojo` (2026-09-16), where each piece read
`ServeOptions`: the signatures here take the worker count and whether a
file-backed page is required, which is all either host decides.
"""

from std.os import getenv, setenv

from lightbug_http.accept_share import (
    AcceptShare,
    SHARED_PAGE_MAGIC,
    SHARED_PAGE_MAGIC_SLOT,
    accept_share_slots,
    accept_sharing_wanted,
)
from lightbug_http.broadcast import BroadcastBus
from lightbug_http.c.process import keep_across_exec

from .multiworker import SharedAtomics


def spawned_worker_index() -> Int:
    """This process's worker index when it was `exec`'d by the supervisor
    under `--spawn-workers`, else -1.

    `M0_WORKER_SPAWNED=1` and `M0_WORKER_INDEX` are set by the supervisor in
    the forked child just before its `execv` (`WorkerSupervisor.enable_spawn`),
    so they are only ever seen by a fresh image whose parent is supervising
    it. Such a process binds nothing: it inherits the listener, the bus
    channels and the shared page by fd number and rebuilds each from the
    environment, then serves exactly as a forked worker of the same index.
    """
    if getenv("M0_WORKER_SPAWNED", "") != "1":
        return -1
    var raw = getenv("M0_WORKER_INDEX", "")
    if raw.byte_length() == 0:
        return -1
    try:
        return Int(raw)
    except:
        return -1


def int_list_env(name: String) -> List[Int]:
    """A comma-separated list of integers from the environment; bad parts skipped."""
    var out = List[Int]()
    var raw = getenv(name, "")
    if raw.byte_length() == 0:
        return out^
    for part in raw.split(","):
        try:
            out.append(Int(String(part)))
        except:
            pass
    return out^


def _csv(values: List[Int]) -> String:
    var out = String("")
    for i in range(len(values)):
        if i > 0:
            out += ","
        out += String(values[i])
    return out^


def shared_id_addr() -> Int:
    """The shared page's address in this process, as `prefork_page` exported it.

    Read from the environment rather than threaded through, because that is
    how it reaches a spawned worker, and a single reader keeps the two paths
    from disagreeing. 0 when there is no page.
    """
    try:
        return Int(getenv("M0_SHARED_ID_ADDR", "0"))
    except:
        return 0


def prefork_page(workers: Int, required: Bool = False) raises -> SharedAtomics:
    """The pre-fork page for `workers` workers: created and exported, or adopted.

    `required`: a file-backed page is the only one that works (the workers
    exec), so failing to make one is an error rather than a fallback.
    """
    var slots = accept_share_slots(workers)
    if spawned_worker_index() >= 0:
        var fds = int_list_env("M0_SHARED_ID_FD")
        if len(fds) != 1:
            raise Error("spawned worker: M0_SHARED_ID_FD is not set")
        var mapped = SharedAtomics(from_fd=fds[0], count=slots)
        _ = setenv("M0_SHARED_ID_ADDR", String(mapped.addr(0)), True)
        return mapped^
    var page: SharedAtomics
    try:
        page = SharedAtomics(slots, file_backed=True)
    except e:
        if required:
            raise e^
        print(
            "the shared page could not be file-backed (" + String(e)
            + "); a child process will publish unnumbered frames",
            flush=True,
        )
        page = SharedAtomics(slots)
    page.store(SHARED_PAGE_MAGIC_SLOT, SHARED_PAGE_MAGIC)
    _ = setenv("M0_SHARED_ID_ADDR", String(page.addr(0)), True)
    if page.fd >= 0:
        # `shared_file_fd` already cleared its FD_CLOEXEC.
        _ = setenv("M0_SHARED_ID_FD", String(page.fd), True)
    return page^


def prefork_bus(channels: Int) raises -> BroadcastBus:
    """One channel per worker (or per loop thread): created and exported, or adopted."""
    if spawned_worker_index() >= 0:
        return BroadcastBus(
            read_fds=int_list_env("M0_BUS_READ_FDS"),
            write_fds=int_list_env("M0_BUS_WRITE_FDS"),
        )
    var bus = BroadcastBus(channels if channels > 0 else 1)
    for i in range(len(bus.write_fds)):
        _ = keep_across_exec(bus.write_fds[i])
        _ = keep_across_exec(bus.read_fds[i])
    _ = setenv("M0_BUS_WRITE_FDS", _csv(bus.write_fds), True)
    _ = setenv("M0_BUS_READ_FDS", _csv(bus.read_fds), True)
    return bus^


def prefork_accept_share(workers: Int) raises -> AcceptShare:
    """The channels accept sharing passes connections over (SPEC E16).

    Inactive -- a value with no channels -- with one worker and under the
    knob; created and exported, or adopted by a spawned worker, otherwise.
    """
    if not accept_sharing_wanted(workers):
        return AcceptShare()
    if spawned_worker_index() >= 0:
        return AcceptShare(
            read_fds=int_list_env("M0_ACCEPT_READ_FDS"),
            write_fds=int_list_env("M0_ACCEPT_WRITE_FDS"),
        )
    var share = AcceptShare(workers)
    for i in range(share.workers()):
        _ = keep_across_exec(share.read_fds[i])
        _ = keep_across_exec(share.write_fds[i])
    _ = setenv("M0_ACCEPT_READ_FDS", _csv(share.read_fds), True)
    _ = setenv("M0_ACCEPT_WRITE_FDS", _csv(share.write_fds), True)
    return share^


def bind_accept_share(mut share: AcceptShare, worker: Int, page_addr: Int):
    """After the fork: this worker's index and the page's address in this
    process. Harmless on an inactive share."""
    if share.workers() <= 1:
        return
    share.bind(worker, page_addr)
