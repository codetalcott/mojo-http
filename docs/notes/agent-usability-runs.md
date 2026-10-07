# Agent usability runs — 2026-10-07

Fifteen headless coding-agent sessions on the two quickstarts' task and
on a Django Channels baseline, scored from their transcripts. The
harness is `scripts/agent_runs.py`; the briefs are `scripts/agent_runs/`.
The transcripts are kept outside this repository.

## The question

An agent that has never seen m0serve or m0 is asked to build what the
quickstarts teach: a page whose open tabs all show a message one of them
posts. It has PyPI, the docs site, the tools on the machine and what it
already knows, and nobody to ask. How many tool calls does a working
result take, where does it stumble first, and how does that compare with
Channels, which it knows from training?

## Method

One run is one `claude -p` session (Claude Code, Opus 5.5, the default
with no settings) started in an empty directory with no settings, hooks,
plugins, MCP servers or CLAUDE.md from the machine, WebSearch and
subagents refused, WebFetch allowed for the track's domains alone, and
the Read tool denied under the directory that holds this checkout. The
brief names the product and its docs URL and nothing the docs say: no
flag, no header, no module. It fixes a contract the harness probes after
the session, without the agent's help: `run.sh PORT` starts the server,
`GET /` is HTML, `POST /messages` with a field `text` adds a message, and
`GET /stream` is Server-Sent Events on which the message reaches two
streams open at once. Five runs a track.

The score is counts from the transcript: tool calls to the end, calls
before the first flagged result, the pages fetched, and any reference to
a checkout of the product on the machine (none, in fifteen). Which
flagged result was the first wrong move is read by a person.

## Result

Fifteen of fifteen met the contract.

| track | tool calls, median (range) | wall clock | cost | wrong moves the product caused |
|---|---|---|---|---|
| m0serve, synchronous Django | 13 (13–15) | 88 s (82–108) | $0.37 | 0 of 5 |
| Django Channels, in-memory layer | 13 (9–20) | 115 s (99–290) | $0.43 | 5 of 5 |
| m0, Mojo | 33 (24–34) | 196 s (187–543) | $1.14 | 4 of 5 |

**m0serve ties Channels on calls**, for an agent that had never seen it.
Every m0serve run fetched the home page through the agent's summarising
fetch, which drops code blocks, then read `llms.txt` and the quickstart
as raw markdown with `curl`, and used only what the quickstart teaches:
the two hold headers, `m0pub.publish()`, `--realtime`. The first flagged
result in every run was the machine's, a launchd m0serve of another
project on the port every agent tried first, answering 403; two calls
each to read the bind failure in the log and move.

**Every Channels run read the framework's source.** Four of five fetched
no documentation and wrote Channels from memory. Every one then found
that `AsyncHttpConsumer` stops as soon as `handle()` returns, so the
documented streaming shape never receives a group message, and overrode
`http_request`, an internal, to keep the consumer alive. Four of five hit
`URLRouter`'s `path("")` not being a catch-all and got a 500 on the POST.
The results run in one process by the layer's nature.

**The Mojo track costs 2.5x the calls.** The calls went to reading the
framework's source: no run reached the host page or the views page. Each
fetched the `/mojo/` overview once through the summarising fetch, which
did not carry it to the pages the overview links, scaffolded `--template
live`, read the scaffold's `AGENTS.md`, which says the source is
installed and readable, and read the source. The one product stumble was
a compile error on `reply.problem`'s required fourth argument, one or two
calls to fix. Every run deleted about half of the live template, whose
producer is a timer, to get a list a request pushes; every run moved the
scaffold up a level, because `m0 new` writes `./NAME` only.

## What each stumble becomes

Counted over the five runs of its track.

Lines on the pages:

- The quickstart's serve command passes `--host 127.0.0.1`, and says the
  default is every interface (5).
- The quickstart says the binary resolves libpython from `PATH`'s
  `python3`, so a start script activates the venv (2).
- The quickstart says what `publish()` does with a newline (one `data:`
  field per line) (4), and without `--realtime` (returns 0, sends
  nothing) (1).
- The quickstart says a view a form posts to is `csrf_exempt` or takes
  the token (2).
- The home page links `llms.txt` and each page's `.md` form where an
  agent's fetch will keep them (4).
- The `/mojo/` overview names the API pieces and the page each is on,
  links `llms.txt`, and does not say "no form library" of a framework
  with `m0_http.form` (5 called the site thin).
- The views page gives `reply.problem`'s four arguments (4).
- The host page says where a send from a view reaches: this process's
  streams, and the bus for the rest (2).
- The scaffold's `AGENTS.md` links the host and views pages, so the
  source is the second stop (5).

Changes to `m0`:

- `m0 new` into the current directory (5).
- The next step `m0 new` prints passes `--host 127.0.0.1` (3).
- A template whose producer is a request, not a timer (5).

The skills, written next, carry the rest: what the runs looked for and
where it was.

## Not measured

One model, one machine, five runs a track. The Channels agent had the
framework in training and the m0serve agent did not; that is the
comparison the claim needs. The Claude Code sandbox was tried for the
network restriction and dropped: its proxy breaks pip's TLS, a failure
the product never causes. The restriction is a rule and an audit.
