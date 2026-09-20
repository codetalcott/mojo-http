# Flags and a doctor for the host — 2026-09-19

A Mojo host application was configured by environment alone. That was
decided, not overlooked: D29 recorded "no CLI flags and no `--doctor`" with
the retiring condition "a flag its operator cannot set in the environment",
and the developer product (host plan, Phase 6) is that condition — a CLI
whose `doctor` delegates to the binary's own needs the binary to have one.
This round gives the host m0serve's command-line contract: flag over
variable over default, strict parsing, and a doctor that exits with the
server's own code. It is SPEC E30 and E31.

## What was built

`m0_host/flags.mojo` is the parser, pure over a list of strings.
`serve[H, P](config)` now begins by laying the command line over the config
it was handed, so `serve(AppConfig())` is still an application's whole
`main`. The flags are what `AppConfig` already carried — host, port,
workers, threads, blocking threads, access log, heartbeat, tick, keep-alive
cap, QoS, `--spawn-workers` (read, then refused exactly as its variable is)
— plus `--doctor` and `--help`.

`Report`, the pure half of m0serve's doctor, moved from m0-wsgi to
`m0_http.doctor` with its first key made a parameter, so the two doctors
render one shape: `ok`, `exit`, grouped facts, and `checks` whose failures
each carry a `fix` and the exit they cause. `m0_wsgi.doctor` re-exports it.

## Question 1: where does the command line get applied?

In `serve`, because that keeps the one-line `main`. But every host app in
the tree prints its own address BEFORE it calls `serve`, from the config it
just built — so under `--port 9000` the banner would name 8080 and the
server would bind 9000.

`AppConfig()` could not simply start reading argv: m0serve builds one too
(`AppConfig(default_port=DEFAULT_PORT)`), and would have its own arguments
parsed twice by two grammars. So there is `host_config()` — `AppConfig()`
with the command line applied, the same exits — for an application that
prints an address, and **the overlay is idempotent**, which is what lets
`serve` apply it again without asking whether someone already did. The six
host apps with a banner take `host_config()`; a scaffold with no banner
keeps `AppConfig()`.

The two-argument `serve(config, server_config)` has the same problem one
level down: `apps/sim_loop` builds its `ServerConfig` and sets its own tick
before the flags are read. `HostFlags.apply_to` lays over it only the flags
that were GIVEN — the operator's explicit word outranks the application's
code; a flag nobody typed leaves the application's value alone.

## Question 2: is `--threads 0` a usage error or a refusal?

m0serve answers its `--workers 0` with 2. The host already refused
`M0_THREADS=0` with 78, and a host that answered the flag with 2 and the
variable with 78 would have two descriptions of one rule. So the parser
refuses only what it cannot READ (not a number, a port out of range, an
unknown flag, a positional), and a count that cannot be SERVED goes down
the one path whichever way it arrived.

That path is `host_checks`: every rule the host refuses by, in the order it
applies them, each evaluated. `host_refusal` — what `serve` exits 78 on —
is its first failure, and the doctor lists them all and exits on the same
first failure. m0serve's doctor mirrors `main`'s check order by hand and
says so in a comment; here the server and the doctor read one list, so
they agree by construction. The gate runs both anyway, for the reason a
by-construction argument is worth one sabotage: reversing the loop in
`host_refusal` is caught only by a configuration that trips two rules at
once, which the first version of the probe did not have.

Each refusal now prints its fix, and the fix names both spellings
(`set --threads (M0_THREADS) to 1 or more`), because the operator may have
used either.

## Question 3: what does the doctor print when the application prints too?

One JSON object, as the **last line** of stdout. An application's banner
comes first, and its OWN refusal (`apps/blobs` checks its cadence in `main`
and exits 78 before `serve`) produces no report at all. That second fact
is what settles the first: a caller already has to handle "exit 78 and no
JSON", so "take the last line, try JSON" is the contract, and the
application is not asked to know whether it is being doctored.

That is also how the contract holds for application-owned configuration
without a hook: those checks run before `serve`, so they fire identically
under the doctor. What the doctor does not do is RENDER the application's
settings; that needs a hook, and no second application has asked.

The report's first key is `"m0_host":"1"` — a format number. The release
version lives in `pyproject.toml` and `cli.mojo` and nowhere else
(docs/RELEASING.md), and a third copy compiled into every app was not worth
what it would say. The `m0` wheel can add its own version from outside.

## What the doctor does not cover

The bind, and the application's `make`. Whether the address is free and
whether the handler can be built are found out by doing them; a doctor
that built the handler would open the application's database to report on
a port. Both fail at run time with a named line (`make` with 78, D30), and
E31 says so rather than claiming the whole contract.

## What is gated

`smoke-host-doctor` (every PR) is `smoke-doctor`'s shape: twenty
configurations of `apps/host_check`, each run as `--doctor ARGS` and as
`ARGS`, the two exit codes required to agree with each other and with the
table. A served row is really served — `/health` on the port the FLAG
names while `M0_PORT` names another, which nothing may then answer on.

**The sabotage found a hole in the gate before anything else did.** Two of
the first twelve rules were MISSED: serving the environment under a
command line that had been read, and withholding a given flag from the
`ServerConfig`. Both passed because the gate app takes `host_config()`,
which applies the command line before `serve` sees it — the banner fix had
hidden whether `serve` does its own job. The probe now runs the flag rows
in both application shapes (`M0_HOSTCHECK_ENV_CONFIG=1` hands `serve` a
bare `AppConfig()`), and both rules are caught. Twelve rules in
`sabotage-host`, seven on the wire and five against the parser's unit
tests.

The spec sheet's closed-set rule covers the new flag set too: every flag
`flags.mojo` accepts must be named by a row, and a row may name a flag
either command line accepts.

## Not built

- The application's own settings in the report (a hook; wait for the
  second application that wants it).
- Flags an application defines for itself. The parser is strict, so an
  unknown flag is exit 2; an application's settings are its variables.
- `--version`. There is no version to print (above).
