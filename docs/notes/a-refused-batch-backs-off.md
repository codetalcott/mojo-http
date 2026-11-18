# A refused batch backs off — 2026-11-17

> A design note from the engineering record. SPEC L44 names the capability.
> It follows L43, which let a lone asyncio executor take up to 1024
> requests at once, more than its submit channel holds on Linux.

An ASGI application that blocks its own asyncio loop (a `time.sleep`, a
synchronous driver call in an `async def`) stops its executor reading the
channel the loop submits requests on. The requests behind it fill the
channel until a submit is refused. The loop put a refused batch back to
wait and offered it again every millisecond, so it spent most of a core
for as long as the application blocked. It now puts the batch back in one
step and waits before offering it again.

## What the channel holds

A UNIX datagram pair, both buffers asked for 262144 bytes
(`_size_socket`), nothing reading, a non-blocking writer:

| datagram | macOS 27.2.1 (ENOBUFS after) | Linux 6.8 (EAGAIN after) |
|---|---:|---:|
| 8 B, one job | 2048 | 555 |
| 129 B, 16 jobs | 1807 | 555 |
| 513 B, 64 jobs | 495 | 333 |

Linux reads both buffers back as 425984 bytes and charges each datagram's
whole buffer against them, so its channel refuses after 555 one-job
datagrams: under the 1024 a default server's executor takes since L43, and
over the 256 it took before, which is why nothing reached this path until
L43. macOS holds 2048, past any bound a default server sets; there it is
reached only with `M0_EXECUTOR_INFLIGHT` set past 2048, which RUNNING.md
offers to a server with more connections than that.

## What a refusal cost

`apps/asgi_bare` on m0serve, `/block?ms=5000` on one connection, then a
request on each of the others half a millisecond apart, so each pass
submits one or two and the channel fills with one-job datagrams. The
server's CPU over the block, and `/health` (answered on the loop) every
10 ms. The Linux rows are a colima VM on the same M4 (4 CPUs, 4 GB); the
client shares the machine. m0serve 1.17.0 at 0f6e9402, CPython 3.14.7 on
macOS and 3.13.11 in the VM:

| | CPU, % of a core | `/health` p99 | refused |
|---|---:|---:|---|
| Linux, 1000 connections, bound 256 | 0.8 - 1.1 | 0.43 - 0.56 ms | no |
| Linux, 1000 connections, default | 65.4 - 66.6 | 2.05 - 2.17 ms | yes |
| Linux, 4000 connections, default bound | 99.3 - 100.5 | 15.0 - 18.1 ms | yes |
| macOS, 4000 connections, default bound | 1.2 | 1.57 ms | no |
| macOS, 4000 connections, bound 4096 | 96.1 | 9.34 ms | yes |

Every request was answered once the application let go. Each retry took up
to 64 requests off the queue, sent them as one batch, which the full
channel refused, and put them back one at a time, each rebuilding the whole
queue behind it: 64 rebuilds of about 445 entries with 1000 connections, a
2 ms pass, then a 1 ms wait, 66% busy. A health request that landed in a
pass waited it out.

## The change

Two parts, each covering what the other leaves:

- **One rebuild a batch.** `hold_waiting_first` takes the whole refused
  batch and rebuilds the queue behind it once. This bounds what a single
  retry stalls the loop for: with 4000 connections, about 3400 of them
  waiting, a health request waited 15-18 ms behind one.
- **A wait before the next offer.** `back_off` sets a wait of 1 ms after a
  refusal and doubles it with each refusal in a row, to 64 ms
  (`SUBMIT_RETRY_MAX_NS`); `_admit_waiting` offers nothing while it runs
  and `_wait_for_events` sleeps until it ends. A job coming back ends it at
  once (`executor_read`): the executor that answered is reading again. This
  bounds how often the retry happens.

Two spikes measured each part on its own before either was built, two runs
each, Linux, default bound:

| | 1000 connections | 4000 connections |
|---|---:|---:|
| before | 66% | 100% |
| one rebuild a batch | 12% | 26 - 33% |
| one rebuild, and a fixed 10 ms wait | 3.2% | 13% |

## After

The same workload against the change as built, same machine, same day:

| | CPU, % of a core | `/health` | refused | runs |
|---|---:|---:|---|---:|
| Linux, 1000 connections, default | 0.8 - 1.3 | slowest 1.4 - 1.6 ms | yes | 3 |
| Linux, 4000 connections, default bound | 2.5 - 3.2 | p99 0.78 - 1.3 ms | yes | 2 |
| macOS, 2600 connections, bound 3000 | 1.1 | slowest 2.2 - 16.3 ms | yes | 3 |
| macOS, 4000 connections, bound 4096 | 2.9 | p99 2.49 ms | yes | 1 |

The 1000- and 2600-connection rows are the gate's own runs
(`asgi_inflight_probe.py blocked`, which asks `/health` on a new
connection every 50 ms and reports the slowest answer); the gate measured
64.2% and 70.7% before the change, and the slowest macOS answer was 16.6 ms
then too. A refusal now costs what no refusal cost (0.8 - 1.1% on Linux at
a bound of 256, above), give or take two points at 4000 connections. Every
request was answered within 44 ms of the block's end, as before.

## What it does not do

The loop cannot see the executor read its channel, only answer: an
executor that reads every request and answers none (each a long poll) is
offered what waits once the wait ends, 64 ms at the most. Nothing is
counted per refusal, and the refusal's stderr line is printed once.
