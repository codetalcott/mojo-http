# What the agent runs asked for — 2026-10-07

The follow-ups from [the agent usability runs](agent-usability-runs.md):
the lines each page lacked, three changes to `m0`, and the two skills.
Each stumble the runs counted became a line on a page, a change to the
tool, or a line in a skill. SPEC N27 and N52; decision D66.

## Lines on the pages

The Python quickstart's serve commands pass `--host 127.0.0.1`, here and
on the page after it, and the page says the default is every interface.
It says the binary resolves libpython from `PATH`'s `python3`, so a start
script activates the virtualenv. It says what `publish()` does with a line
break and what its return value means, and that a form a page posts meets
Django's CSRF check. The home page says, above its first fold, that
`llms.txt` indexes every page and that each page is Markdown at its URL
with `.md` in place of the trailing slash: four of five Python runs
fetched the HTML page first, through a fetch that summarises and drops
code blocks.

On the Mojo side, the overview has a table of the API pieces and the page
each is on, links `llms.txt`, and no longer says "no form library" of a
framework with `form(req)`. The views page gives `reply.problem` its four
arguments, the other `reply` helpers beside it. The host and views pages
say where a send from a view reaches. The scaffold's `AGENTS.md` names the
host and views pages by URL before it names the installed source, which is
where all five runs went first.

## Three changes to `m0`

- **`m0 new .`** writes the empty current directory and takes its name.
  Every Mojo run wrote `./NAME` and then moved the files up a level; one
  then saw `m0 doctor` report the moved files.
- **The printed next step binds `127.0.0.1`**, as do both quickstarts.
- **`--template board`** is a list every tab shares, whose sender is a
  view. Every run chose `live` and deleted about half of it, because its
  producer is a timer and the task's sender was a request.

## The board, and two facts it rests on

`POST /messages` appends to a list held in the state and publishes the
whole board through the state's `DatastarStream`: no producer, no
database. Two facts about Datastar 1.0.4 shaped the rest, each read off
the bundle rather than remembered.

- **An action's answer is applied only when its status is 200.** The
  fetch code returns after its retry decision for any other status, so a
  422 fragment never reaches the page, unlike htmx 4, which swaps every
  4xx. The board keeps an empty message in the browser with `required`,
  and answers a client that bypasses it with `reply.problem`.
- **The morph keeps a typed value unless the `value` attribute changed**:
  it compares the old element's attribute with the new one's, not the
  property. Answering the form again would not have cleared it. The
  input is bound to `$text`, and the POST answers `application/json`
  `{"text":""}`, which Datastar reads as a signal patch.

The form is a fragment of its own outside the streamed board, so a frame
replaces the board in every tab and leaves another visitor's draft alone.

Every view that touches the state is `on_loop=True`. Under
`--blocking-threads N` the host builds a state for each pool thread, and a
post answered there lands in a list and a stream nobody reads. The gate
serves the board behind a pool for that reason, and the template's own
`smoke.sh` serves it without one, so both shapes are on the wire. Each
`on_loop` reverted alone fails the gate in its own way: the post reaches
no stream, the stream is refused 409, or the document shows an empty
board.

The same rule found a defect in `live`: its `/events` view was not
`on_loop`, and its handler answered only stateless loop routes, so behind
a pool every stream was refused 409. Nothing served `live` behind one.
The gate now serves both streaming templates behind a pool.

`ViewsApp` forwards three stream hooks and not `sse_peer_frame`, so a
views application cannot deliver another worker's frame. The board stays
one process (`max_workers() -> 1`), and D66 records what would add the
hook.

## The gate

`smoke-scaffold` holds the board as it holds the others, and adds the
current directory to every template's `new` phase. `sabotage-scaffold`
gained ten rules for the board, two for `live`'s stream and two for
`m0 new`, each run once before landing.

## The skills

`skills/m0serve/SKILL.md` and `skills/m0/SKILL.md` carry what the runs
looked for and where they found it. They live in this repository, so a
change to the product changes its skill in the same pull request. The
repository is public, which makes it where a reader installs them from;
the owner's private `wtalcott` marketplace carries them as a plugin whose
upstream is this directory. The run harness gained `--plugin-dir`, which
loads a plugin into every session of a run and records its version and a
hash of its files.

## Not measured yet

The re-runs. The doc lines reach an agent once the site is deployed, and
the `m0` changes once a release publishes them, so the Mojo track is
re-run after the next `m0` release. The Python track with its skill
loaded measures the skill alone, against the site as it stands.
