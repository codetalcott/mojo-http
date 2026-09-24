# m0-datastar: rules for changing this package

The Datastar wire format (`src/consts.mojo`, `src/sse.mojo`) and the server
glue that fans it out (`src/stream.mojo`, `src/signals.mojo`). It targets
Datastar **v1.0.4**, the `VERSION` in `src/consts.mojo` and DECISIONS D20.
The repository's `CLAUDE.md` still applies; this page adds what is specific
to Datastar.

## Where Datastar facts come from

Do not take them from memory, the docs site's prose, or another SDK's README.
All three have been wrong here before. Use these sources, in this order:

1. **The client bundle at the pinned tag.** It is what the browser actually
   does. `curl -sSL https://cdn.jsdelivr.net/gh/starfederation/datastar@v1.0.4/bundles/datastar.js`,
   then `grep -o`. The bundle is minified, so a summarising fetch of it is
   unreliable; `grep` is exact.
2. **`test/sdk/ADR.md`**: the SDK specification, vendored from the tag.
3. **`test/sdk/test/`**: the SDK's own conformance cases and the
   `compare-sse.sh` that judges them. `poe check-datastar-sdk` runs every
   one (SPEC I27).
4. **The Go SDK** (`github.com/starfederation/datastar-go`), the ADR's
   reference implementation. It moved out of the main repository.

When the bundle and the ADR disagree, the bundle decides what reaches a
browser. Record the disagreement on this page.

What those sources said at v1.0.4 (checked 2026-09-24):

- **Where signals travel.** In `?datastar=` on GET and DELETE, and in the
  body on every other method: the bundle's `mt=e=>!["GET","DELETE"].includes(e)`
  and the ADR's `ReadSignals` table.
- **Form actions.** An action sent with `contentType: 'form'` carries the
  form and no signals.
- **Repeated datalines.** The client splits each dataline at its first
  space and joins datalines of the same key with `\n`. That is why a value
  that spans lines goes out as one dataline per line.
- **Reconnects.** The client sends `last-event-id` when it retries, so the
  replay journal is exercised by real browsers.
- **Datastar has no redirect.** Neither the ADR nor the Go SDK has one;
  `redirect` here is this package's own helper.

## Moving the pin

1. `python3 scripts/datastar_conformance.py --fetch vX.Y.Z` re-vendors the
   ADR, the comparator and the cases, and rewrites `test/sdk/MANIFEST`.
2. Read the spec's diff: `git diff packages/m0-datastar/test/sdk/ADR.md`.
3. Move `VERSION`. The gate refuses fixtures from any tag other than the
   pinned one. Then grep the tree for the old version: the apps' CDN URLs,
   README, the docstrings.
4. Re-check every fact in the list above against the new bundle.
5. `uv run poe test-datastar check-datastar-sdk sabotage-datastar-sdk`.

A fixture field the harness does not map fails the run by name, so a new
SDK option cannot be dropped silently. Map it in `event_call`.

## Wire rules (`sse.mojo`)

- **`consts.mojo` and `sse.mojo` import nothing outside themselves**, so the
  wire format is usable without the framework. Do not add an `m0_http`
  import to either.
- **Field order is `event`, `id`, `retry`, then the data lines.** Only
  non-default datalines are written, and an empty `elements` writes none:
  `remove` mode takes a selector and nothing else.
- **A value that may span lines is split, one dataline per line.** That
  means `elements`, `signals`, and a script, which travels inside
  `elements`. The splitter is `split_data_lines` (CRLF, CR and LF).
  - It cuts BYTE spans, never `[byte=a:b]` (SPEC G14).
  - It is a deliberate copy of `m0_http`'s `split_sse_lines`. Fix both, or
    the copy keeps the bug.
- **A value that must stay on one line raises on CR or LF** (SPEC I29).
  That covers the selector, mode, namespace, view-transition selector and
  event id. Two line breaks end the event and let the sender open one of
  their own. A new single-line field gets its own `_refuse_line_break` call.
- **`redirect` writes its location through `_js_string`.** Do not paste it
  between quotes.
- **`execute_script`'s `attributes` go out verbatim**, the Go SDK's shape,
  so the caller escapes them.

## Server glue (`stream.mojo`, `signals.mojo`)

- **`read_signals` returns the JSON as text**, not a parsed model. Callers
  read fields with `m0_core.json_parse`.
- **Every `DatastarStream` broadcast raises when its frame would.** The id
  it allocated is then skipped, and nothing depends on ids being
  contiguous.
- **Replay versus `send_latest`.** Replay catches a stream of changes up
  from the journal after `Last-Event-ID`. `send_latest` sends the newest
  state at `open` and never replays (SPEC I24). Under `send_latest`, every
  frame on a URL must be a whole state: whatever went out last is what the
  next subscriber gets.
- **A catch-up is all or nothing** (SPEC I30). The outbox holds 64 KB per
  slot (`MAX_PENDING_BYTES` in m0-http). A reconnect gets no replay at all
  in any of these cases:
  - the journal has evicted a frame it missed;
  - its id predates this process's history (the `floor`: the first
    restored frame, or the ids siblings used before a respawned worker
    joined);
  - its id is ahead of the counter;
  - its missed frames will not fit the outbox.

  In every case `caught_up(slot)` is False, and the view `send_to`s the
  current state, unnumbered. Never "replay what fits": replayed oldest
  first, the frames refused are the newest ones.
- **Cross-worker streams take their ids from the shared atomic.**
  `enable_bus`, `deliver_peer` and the bus wiring are described in the
  struct docstring; `apps/datastar_counter` is the reference.

## Gates

| What | Gate | SPEC |
|---|---|---|
| Every SDK conformance case, judged by the SDK's comparator | `poe check-datastar-sdk` | I27 |
| `read_signals` reads GET and DELETE from the query | `test_stream.mojo`, and the same harness | I28 |
| Line breaks refused; the redirect literal escaped | `test_frame_injection.mojo` | I29 |
| The newest state sent at `open` | `test_stream.mojo` | I24 |
| A catch-up the journal cannot give is reported, not sent in part | `test_stream.mojo`, `smoke-todo` | I30 |
| Invalid UTF-8 after a line break does not trap | `test_sse.mojo` | G14 |
| A fragment is one `elements` line | `test_fragment_frame.mojo` | N7 |

After changing a line `scripts/datastar_conformance.py` names in
`SABOTAGES`, run `poe sabotage-datastar-sdk`: its anchors are exact source
lines, and a stale one fails as ANCHOR MISSING.

**Name new test files uniquely.** The spec sheet indexes test files by file
NAME across packages, and m0-http has its own `test_sse.mojo`, so no row
can cite this package's copy of that file. A test a row cites goes in a
file whose name no other package uses.
