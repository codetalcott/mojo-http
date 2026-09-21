# The Mojo stack's pages, and a front door CI walks through — 2026-09-20

The fourth round of the work that lets an application in Mojo be written
outside this repository. The first three built the product — the `m0` wheel
([the-m0-wheel](the-m0-wheel.md)), `m0 new` and its templates
([the-scaffold](the-scaffold.md)), `m0 dev`, `m0 image` and the release
workflow ([dev-image-and-a-release](dev-image-and-a-release.md)). This one
documents it: six pages on the site, a Mojo-stack section in `llms.txt`,
and a gate that executes the quickstart. SPEC N33–N35; decision D45.
Nothing is published: no tag, no upload, no site deploy.

## The one question settled first

`uvx m0 new` installs a placeholder `0.0.1` from PyPI on the day this was
written, and the placeholder has no `new`. A front door cannot be written
both ways and chosen later, so the owner was asked once: `m0 0.1.0` is cut
before these pages are public. The pages therefore say `uvx m0 new`
plainly, and the site — which deploys on a release or a dispatch, never on
a merge — must not be deployed with them until that version is on the
index. docs/RELEASING.md's m0 procedure gained the step that closes the
loop: after the upload, the page is run verbatim against the index, which
is the only run in which its first line means what a reader's does.

## Where the executable page lives, and why

`test.yml` ignores `*.md` at the root and `docs/**`. `QUICKSTART.md` lives
with that: a pull request editing only that page runs no gate, and the
defence is that doc-only pull requests cannot automerge. The new page is
`packaging/m0/QUICKSTART.md` instead. A path glob's `*` does not cross a
`/`, so nothing under `packaging/` is ignored, and a pull request that
edits only the page runs `Tests` — the asymmetry `docs.yml`'s header
records as a defect, used on purpose. The site's page table takes a source
from anywhere, so the URL is `/mojo/quickstart/` all the same.

## The gate

`smoke-quickstart-mojo` is `run_quickstart.py` — the mechanism that runs
`QUICKSTART.md` — given `M0_WHEEL`. Three things are the gate's and not the
reader's, each because the tree's wheel is `0.1.0+tree`, rebuilt under one
version that no index serves:

- `uvx m0` becomes `uvx --from <the wheel file> m0`, and `UV_FIND_LINKS`
  names its directory, so the project's exact pin resolves to it.
- The page's `uv sync` gains a refresh of `m0` and is followed by
  `smoke-scaffold`'s byte-equality check. That gate once compiled
  yesterday's framework because uv caches a version by name; the same hole
  was open here from the first line written.
- The blocks run on a stripped `PATH` — uv's directory and the system's —
  with `VIRTUAL_ENV` and its kin dropped. The runner is started by
  `uv run poe`, inside this repository's venv, which holds a `mojo` and
  could hold an `m0`: a quickstart that passes because its environment
  already has what the reader's lacks proves nothing. `UV_PYTHON` names the
  interpreter, because the system `python3` on a macOS runner is below
  m0's floor and downloading one is a network flake; a Python is not a
  toolchain.

A page on which neither substitution matched is refused rather than run
against whatever the index serves, and the task pins the page's exact block
counts as `smoke-quickstart` does.

It is a second step of the `scaffold-dev` job, not of `smoke`, which has no
slack; it needs the wheel and nothing `smoke` builds. Three builds: the
first, `m0 dev`'s unchanged rebuild, and the one after the page's edit.

**The image step is display-only.** Half the gate's runners have no docker,
a SPEC row cannot cite a step carrying an `if:`, and running the page's two
lines in `pid1` would need the named-build-context apparatus that
`smoke-scaffold-image` already is. N31's gate runs the user's literal
`uv run m0 image` on a scaffolded project; the page says its own gate does
not, and points there.

## What the gate found on its first run

Every scaffolded project's first build began with a compiler warning. Both
templates' entry files opened their docstring with the application's name,
and the compiler's summary lint wants a capital or a non-alphabetic
character there. `check-templates` compiles the files unsubstituted, where
`__M0_APP__` opens with an underscore and passes; `smoke-scaffold` captures
the build's output and never read it. Only a written project, built with
its output on a terminal, shows it — which is what a quickstart runner is.
The name is backticked (the form the style guide asks for anyway), and
`smoke-scaffold` now refuses a first build that prints `warning:`. With
the backticks removed from one template, it fails naming the file and the
lint (N34).

The scaffold's `AGENTS.md` gave `m0 test` as 2–3 s; the `views` template
measures 4.0 to 4.2. It says 2–4 s now, and "four to five times faster
than the build loop" became "three to five".

## Sabotage

The gate's arms are copies of the page with one lie each, run through the
gate's own runner:

| arm | the lie | result |
|---|---|---|
| control | a reworded `echo` | passes |
| command | `uv run m0 tests` | caught, exit 2 |
| wire | the created item expected as `bread` | caught |
| fence | the doctor block's tag removed | caught by the pinned counts |
| literal | the edit step asserting a sentence the template does not serve | caught |
| noedit | the edit itself removed, so nothing is rebuilt | caught, after the wait for the new sentence ran out |
| port | the server started on another port than the probes use | caught, curl's exit 7 |
| envprobe | a block inserted first that fails if `mojo`, `m0` or a venv is reachable | passes |

Each caught arm failed in the block that held its lie, read from the log
and not from the exit code alone.

The last arm is the standing question asked of this gate — does its shape
hide the path it claims? — and it must PASS: nothing is reachable before
the page installs it. A probe that cannot fail proves nothing, so it was
run once more through a copy of the runner with the stripped environment
reverted, and failed on the first block naming this repository's
`.venv/bin/mojo`. The probe then moved into the runner itself, ahead of the
page's first line, so the question is asked on every run and not once.

A stale number is `check-docs`' to catch, not the gate's: the quickstart's
two loop times must be the figures the scaffold's `AGENTS.md` ships, and
"0.7–1 s" in their place is one of the thirteen mutations
`mojo_pages_problems`' selftest reverts (N35). The others move a slug, drop
a page from the site's table, add a refusal or a flag in the host's source,
reorder the page's refusal table, delete a flag's row, reorder m0's checks,
rename a subcommand in the parser, move the scaffold's test time without
the page, point the scaffold's link at a page that does not exist, run a
subcommand m0 lacks in a code block, and strip a fence tag — the last so
that a lost tag is named by the required check, in seconds, as well as by
the gate.

What none of it can show: that a sentence about a flag is true. The lists
are held; the prose was checked by hand against `host.mojo`, `flags.mojo`
and the three notes, once.

## `llms.txt`, measured

The section index asked for a measurement before deciding whether the Mojo
pages get an `llms-full.txt` of their own. The six pages are about 5,000
words; the existing file is about 34,000 with them in it. They ride in the
existing file, non-optional, and `llms.txt` gains an operating-contract
section for the stack in the register the m0serve half already has: what
each command does, the closed set of exit codes, the rule that a refusal is
read and not retried, and the three rules an agent most often gets wrong
(no hand-typed swap attributes, no `[byte=a:b]` slice of request data, no
middleware).

## Not done

- A docker block the page's own gate executes (above).
- A guard that the site is not deployed before `m0 0.1.0` is on the index.
  It would be a network check in the deploy workflow; today it is a
  sentence in docs/RELEASING.md.
- `README.md`'s 29 bare figures, which the figure rule still does not read.
