# Handoff: the three follow-ups from the 2026-09-05 audit

## Record — done 2026-09-05, three PRs, none labelled automerge

| item | PR | outcome |
|---|---|---|
| 1. Retire `OwningList` | [#237](https://github.com/codetalcott/mojo-http/pull/237) | Done everywhere; `owning_list.mojo` deleted. Parity measured: hello keep-alive 171.6k/172.7k/174.8k → 172.8k/173.7k/176.4k req/s (c16/c64/c256), `bench_http_parts` whole request 2.11 → 2.05 µs. The probe the handoff asked for: `ExecutorState` stays behind an address not because of the container but because the derived `Writable` recurses into `HTTPResponse`, whose cookie jar holds a `Dict` that is not `Writable`. |
| 2. Shim source file | [#238](https://github.com/codetalcott/mojo-http/pull/238) | Part A answered first — `docs/notes/shim-language.md`: Python stays; the language-neutral share is under 0.4 µs of a 3.1 µs Python side, every candidate move adds crossings or takes the datagram grammar out of the sabotage-proven guard, and everything behind `ExecutorPort` cannot run on free-threaded CPython. Part B built: `packages/m0-wsgi/shim/m0_shim.py` + `scripts/render_shim.py` → `src/shim_source.mojo`; `check_shim_rendered` in check-docs, `--selftest` in the task and `docs.yml`, a real sabotage went red; pyflakes in `docs.yml` and `poe lint-shim` (found the one unused import); `test-shim` 10/10 sabotages against the file; `stress-asgi` 30/30 both modes; `smoke-wheel` self-contained. |
| 3. Minor cleanups | [#239](https://github.com/codetalcott/mojo-http/pull/239) | `StringSlice` → `StringSpan`, 98 sites in 39 files. Both bodies proven dead by the invalidation test (green through build-all, test-all, build-apps, build-serve): `memmove` deleted; `Socket.send_to` was uninstantiated, so the UDP send path went with it — `UDPConnection.write_to`, `sendto` binding and wrapper, 21 `Sendto*Error` structs and the `SendtoError` variant. 743 lines net. NOTICE and CHANGELOG record both. |

Every PR finished with the CI-shaped run (`test-all` teed → `check-warnings` at 0 of 0, `check-docs`, `build-apps`, `smoke-hello`) plus the item's own smokes; results are in each PR's last comment. Each branch is from `main` independently; #237 and #238 both add a CHANGELOG bullet under Unreleased (Changed and Added respectively) and #239 adds a Removed section, so expect a trivial CHANGELOG merge on the second and third. Two things learned on the way, worth keeping: an invalidation probe inside a METHOD must sit at the body's indentation or the compiler reports a parse error, not a dead body (the first attempt on `send_to` failed that way); and `black` without `--target-version` formats for a newer Python than the one running and skips its own AST safety check — pass `--target-version py39 -S`. `.claude/handoffs/` is gitignored, so this record lives only in the worktree copy (`.claude/worktrees/audit-followups/.claude/handoffs/audit-followups.md`) until it is copied over the main checkout's file by hand — the worktree session's guard cannot write outside the worktree.

---

You are picking up `mojo-http` at `main` on or after `f9f8a58` (PR #236,
"Audit fixes"). Read `CLAUDE.md` first, then run `uv run poe milestones`.
The audit report is at
https://claude.ai/code/artifact/beba1a3f-aaf7-4090-ab46-6788dd71470f; its
"Implemented" section says what PR #236 already did. Three items were left
open on purpose, each because it needs a measurement or a decision rather
than a text edit. Do them as three separate PRs, in the order below, each
branch-first (`main` is ruleset-protected) and without the `automerge`
label unless the user says otherwise.

Rules that apply to all three, all learned the hard way in this repo:

- **Probe before believing.** Every "the toolchain cannot" claim the tree
  made was false on Mojo 1.0.0 (ed45d567). If a step below stalls on such a
  claim, write the ten-line program in the scratchpad and run it under
  `uv run mojo run` before designing around it.
- **Sabotage every guard you add**, and read the sabotage output for
  `MISSED`/`NOT APPLICABLE`, not for the caught count. A guard that cannot
  fail is decoration.
- **Two other sessions may share the main checkout.** `ListAgents` first.
  If any are active, work in a worktree (`EnterWorktree`); the worktree's
  Bash guard refuses loops over variables, heredocs it cannot read, and
  paths outside the worktree — put helper scripts in the ignored `bin/`
  and run them plainly. Build inside the worktree (`uv sync` first).
- **A `src/` edit is invisible to `bin/m0serve` until `build-http` +
  `build-wsgi` + `build-serve`**; a `lightbug_http/` edit needs only
  `build-serve`. A green `mojo run` over `src` is not a compile of the
  package.
- **Finish each PR with the CI-shaped run**: `test-all` teed into
  `compile.log`, then `check-warnings compile.log` (the baseline is now
  **0**, so any new warning is red), `check-docs`, `build-apps`,
  `smoke-hello`. Items that touch the loop or the executor also get
  `smoke-asgi`, `smoke-django`, `smoke-wsgi-stream` and, before a release,
  `stress-asgi`.

---

## 1. Retire `OwningList`

**Why.** `packages/m0-http/lightbug_http/utils/owning_list.mojo` is a
~400-line copy of `List` written when `List[T]` needed `Copyable`
elements. On the pinned toolchain `List` and `Optional` take a
Movable-only, non-`Copyable` struct (proved by probe during the audit:
append, pop and `Optional` wrap all compile and run). The copy is now
maintenance without a reason, and it is on the loop's hot path.

**Where it is used** (seven files; count the sites with
`rg -n 'OwningList\[' -g '*.mojo' packages`):

| Element type | Where | Notes |
|---|---|---|
| `Bytes` | `event_loop.mojo` (`slot_response`), `server.mojo`, `client.mojo` | per-slot response buffers; hot |
| `WSState` | `event_loop.mojo` (`slot_ws_state`), `offload.mojo` | per-slot WebSocket state; hot |
| `ConnectionProvision` | `server.mojo` (`ProvisionPool`) | Movable-only struct with buffers |
| `WSGIApp` | `handler.mojo` | one per mount; not hot |
| `T` | `owning_list.mojo` itself | |

`asgi_executor.mojo` reaches `ExecutorState`'s tables by address. CLAUDE.md
records that `PythonModuleBuilder.add_type` DERIVES a `Writable` from a
bound type's fields and that an `OwningList` field cannot be derived —
check whether a `List` field can (probe it), because that is what decides
whether `ExecutorState` can hold one directly or must stay behind the
address indirection.

**API to reconcile** (`OwningList` methods): `append`, `insert`, `extend`,
`pop`, `reserve`, `resize`, `clear`, `bytecount`, `steal_data`,
`__getitem__` (returns a ref), `unsafe_ptr`, plus ASan container
annotations. `List` covers all but `bytecount` and `steal_data` (deprecated
on `List` too — `unsafe_take_allocation` is the 1.0 name). Grep callers
of those two before deciding whether they need a free function.

**Steps.**

1. Baseline first, on an idle machine: `scripts/bench_http_parts.mojo`
   (the in-context per-part timings; the audit memory says a part timed
   alone can be a fifth of its real cost) and `scripts/bench_hello.sh` for
   loop rps. Record both numbers in the PR description before changing
   anything. Keep-alive rows first; a `Connection: close` run poisons the
   next one for ~30 s on macOS.
2. Replace `OwningList[X]` with `List[X]` file by file, hot files last.
   Where `__getitem__` was relied on to return a `ref`, `List` does the
   same on 1.0; where a site moved out of the list, `pop` or
   `unsafe_take_allocation` replaces `steal_data`.
3. Build with `build-all` and read the warning count: any deprecated
   spelling the swap pulls in (`steal_data`) shows up there, and the
   baseline is 0.
4. Re-run the two benches. **Keep the change only if the numbers hold**
   (within noise on `bench_http_parts`'s response-buffer rows and within
   2 % on `bench_hello.sh`). If `List`'s growth policy or bounds checks
   cost measurably on the per-slot tables, say so with the numbers, keep
   `OwningList` for the hot two sites only, and retire it everywhere else.
5. Delete `owning_list.mojo`, its two `unsafe_alloc` sites go with it, and
   add a NOTICE bullet under the fork's change list (it is a fork file).
   Fix CLAUDE.md's Mojo 1.0 pattern 9, which currently calls `OwningList`
   "a retirement candidate once the swap is measured".

**Done when**: `test-all`, `smoke-asgi`, `smoke-django`, `smoke-wsgi-stream`
and `smoke-blocking-threads` pass on both CI legs, the two bench numbers
are in the PR body next to the baseline, and no `OwningList` remains.

---

## 2. Give the executor shim a source file — after confirming Python is the right home for it

**What it is.** `SHIM_SOURCE` in `packages/m0-wsgi/src/bridge.mojo` (from
line ~103, ~1,500 lines) is a Python program in a Mojo string, `exec`'d
into a fresh namespace per `PyBridge` (`bridge.mojo:1761`). It holds the
WSGI/ASGI protocol dispatch, the asyncio executor loop, the per-slot task
ownership rules, credit windows, the pub/sub fan-out and the WebSocket
seam. `scripts/shim_ownership.py` extracts it by scanning for the
`comptime SHIM_SOURCE = """` opener, unescapes it, and drives it through
real socketpairs; `poe test-shim` runs that suite plus a sabotage of each
rule. No editor, formatter or linter sees the program in place; the audit
ran pyflakes on an extraction and found one unused import.

**Part A — verify that Python is the correct implementation.** The user
asked for this explicitly; do it before any extraction, and write the
answer down (a short `docs/notes/shim-language.md`, or a section in
`docs/notes/executor-python-objects.md`). The question is which parts of
the shim *must* run as Python and which could move to Mojo behind
`ExecutorPort`. Read first: `docs/notes/executor-python-objects.md`,
`docs/notes/loop-inversion.md`, `docs/notes/pump-pacing.md`,
`docs/notes/wsgi-vs-asgi-history.md` (§5 and §8 especially), and the
handoff `executor-python-objects-and-c-api-response-read.md`. Then answer,
with evidence:

- What the shim does that only Python can do here: run the application's
  own coroutines on an asyncio loop (uvloop-compatible), present the ASGI
  `receive`/`send` callables and the WSGI `start_response` protocol, own
  Python objects on the executor thread (the GIL discipline in CLAUDE.md
  says every Python object stays owned by that thread), and call INTO Mojo
  for every event through `_port.dispatch` (~70 ns a call).
- What it does that is language-neutral bookkeeping and could be Mojo
  without crossing the GIL more often than today: credit-window arithmetic,
  frame encoding, channel-name parsing. For each candidate, count the
  extra Python→Mojo calls a move would add per request and compare with
  the measured executor cost in `docs/WSGI_PERFORMANCE.md` (the bridge is
  ~2.5 µs; the executor's Python side was 5.74 → 3.82 µs in PR #232).
- The two hard constraints: the executor cannot exist on free-threaded
  CPython at all (`PythonModuleBuilder` writes the 16-byte `PyObject`
  header; ROADMAP known issue, modular/modular#5726), and shared mutable
  Python objects across threads are the measured 0.7x cliff.

The expected conclusion is that the shim stays Python and is the right
shape for what it does, with perhaps a short list of bookkeeping helpers
worth moving later. If the evidence says otherwise, stop and report
rather than extracting; a port is a different project.

**Part B — extraction, keeping the single binary.** Mojo has no
`include_str`, so the source of truth becomes a file and the Mojo constant
is generated from it:

1. Create `packages/m0-wsgi/shim/m0_shim.py` with the exact current text
   (use `shim_ownership.py`'s extractor so the unescaping is right; the
   string uses Mojo escapes the extractor already understands).
2. Add `scripts/render_shim.py` that writes
   `packages/m0-wsgi/src/shim_source.mojo` containing only
   `comptime SHIM_SOURCE = """..."""` with the escaping reversed, and a
   `--check` mode that fails when the rendered file is stale. Wire
   `poe render-shim` and add `check_shim_rendered` to
   `scripts/check_docs.py` with a sabotage entry (edit the `.py`, do not
   re-render, expect red), the same shape as `render-bench-docs`.
3. `bridge.mojo` imports `SHIM_SOURCE` from `shim_source.mojo`;
   `shim_ownership.py` reads the `.py` directly and stops scanning
   `bridge.mojo`. Keep `test-shim`'s `--sabotage` working against the
   `.py`; its patches currently target lines inside the Mojo string.
4. Run pyflakes and black on the `.py` and add pyflakes to the `Docs`
   workflow's steps if it is not already there (check first: the audit
   found it is not).
5. Commit the rendered `.mojoc`-facing file; `precompile src` must see it.

**Traps.** Every shim function imports `asyncio` itself on purpose: a
missing import surfaces as streams truncated at 64 KB with a log line that
says only "raised after its head" (memory: "The shim is a string; a
NameError hides"). Run the 32-stream `smoke-asgi` check after any shim
edit, however small. Leave the `# noqa`-style deliberate imports alone.

**Done when**: Part A's note is committed; `SHIM_SOURCE` has one source of
truth in a `.py` file; `check-docs` fails when the render is stale and the
sabotage proves it; `test-shim`, `smoke-asgi`, `smoke-django-realtime`,
`smoke-hybrid` and `stress-asgi` pass; the binary is still self-contained
(`poe smoke-wheel`).

---

## 3. Minor cleanups

Two mechanical items, one PR. Both verified by `build-all` + `test-all`
with the ratchet at 0.

**a. `StringSlice` → `StringSpan`, 97 sites.** `StringSpan` is the 1.0 name
and is in the prelude (no import line anywhere uses `StringSlice`, so this
is a pure identifier substitution in `packages/`, `apps/` and
`scripts/*.mojo`). The alias is kept upstream "for the time being" and
will warn on a later pin; the tree already avoids the one spelling that
warns today (`as_string_slice`). Do it with `rg -l 'StringSlice'` +
`sed`, then build. Do not touch the fork's `NOTICE`: a rename of an alias
is not a material fork change.

**b. The two bodies with deprecated spellings the compiler never
flagged.** The 1.0 changelog says `init_pointee_copy` and `as_immutable`
warn when *called*; neither does in the tree's log, which means the
bodies are never instantiated. Confirm before deleting, by the repo's
own method: make each body invalid (a bare `undefined_name` line) and run
`build-all` + `test-all`; if both stay green the body is dead.

- `memmove[...]` in `packages/m0-http/lightbug_http/io/bytes.mojo:316`
  (uses `init_pointee_copy` at 346 and 351). The audit found **no
  callers** in `packages/` or `apps/`. Delete the whole function if the
  invalidation test agrees.
- `sendto[...]` in `packages/m0-http/lightbug_http/c/socket.mojo:1407`
  (`as_immutable()` at 1448). This one HAS a caller —
  `Socket.send_to` at `lightbug_http/socket.mojo:652` — so it is the
  caller that is uninstantiated, not the callee. Decide by the same test
  whether `send_to` is dead too (a UDP path this HTTP server never takes);
  if it is, delete both and the `sendto` error types in
  `c/socket_error.mojo` that exist only for it; if it is not, change the
  spelling to `as_imm()` and leave the function.

Record deletions from the fork in `NOTICE` (one bullet under the fork's
change list), since removed upstream surface is a material change.

**Done when**: `rg StringSlice` returns nothing outside `NOTICE`'s history,
the two spellings are gone, `build-all` is warning-free, and `build-apps`
passes (an app might have used `memmove`; the grep says no, the build
proves it).

---

## Reporting back

For each PR: what changed, the gates run with their results, and for
item 1 the before/after bench numbers in a table. If any item is stopped
by a measurement or by Part A's answer, say exactly which number or
finding stopped it — a "not done" with the evidence is a finished result
here.
