#!/usr/bin/env python3
"""The differential corpus on the wire, held to its frozen table (SPEC B25).

Every case of `differential_corpus.py` goes to the server on PORT on a
connection of its own: the bytes, then SHUT_WR, then everything the server
sends until it closes. The server is `apps/request_echo`, whose application
answers each request the loop hands it with a 200 naming what it saw, so a
response says whether the server parsed a request or refused one, and which
request it was. What came back is the case's OUTCOME, a list in the order
it arrived:

    "GET bl=0 h=1a2b3c4d"  a request the application saw: its method, its
                           body length and the fingerprint of what else it
                           saw (below)
    "400"                  any other response, by its status: a refusal,
                           or a 100
    "PARTIAL"              a response cut short
    "RST"                  the server reset the connection, before the
                           request was all sent or after
    "OPEN"                 the server had not closed it CAP seconds after
                           the request
    "NONE"                 no response at all, and the connection closed

The fingerprint is the first eight hex digits of a SHA-256 over the request
target as the application routes on it (`request_uri`), the protocol, and
every header line it was handed, in the order handed, each name lowercased
(ASCII only: `bytes.lower`). Every field is its raw bytes behind its length,
so the digest depends on nothing but those bytes: not on a locale, an
encoding or the platform. The echo's `target` and `host` are left out: they
carry the server's own listening address and port, which a free port moves
on every run. The `Host` the application reads is a header line.

The gate compares each outcome with the case's `ours` in
`differential_expected.json`, prints every case that differs with both
outcomes, and fails on any, as it does on a case the table has no row for
and on a row no case has. Every case ends in a close today, within
milliseconds of its request, so a 1 s cap is reached only by a server that
has stopped closing; three such cases in a row end the run there rather than
spend a second on each of the rest. After the corpus one plain GET must
still be served: a case that killed the server is not passed by being last.

`differential_corpus.py` says how the table grows: `--print` and `--freeze`
read the same outcomes from any server answering the echo's JSON, the two
reference echoes beside this file included.

usage:
    differential_probe.py PORT                    the gate
    differential_probe.py PORT --only NAME        one case
    differential_probe.py PORT --print            each case's outcome, nothing compared
    differential_probe.py PORT --freeze [COLUMN]  write the table's COLUMN (`ours`,
                                                  `h11` or `llhttp`) from PORT
"""
import argparse
import hashlib
import json
import socket
import time
from pathlib import Path

from differential_corpus import CASES
from probelib import fail, phase, stamp

stamp("differential_probe: FAIL")

TABLE = Path(__file__).resolve().parent / "differential_expected.json"
CAP = 1.0
# This many cases in a row still open at the cap end the run.
OPEN_RUN = 3
COLUMNS = ("ours", "h11", "llhttp")
# A row's keys, in the order the table is written.
KEYS = COLUMNS + ("note", "known_divergence")
PLAIN_GET = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"


def exchange(port, raw):
    """What the server sent for `raw`, and how the connection ended: EOF,
    RST, or OPEN when it had not closed within CAP seconds. A reset while
    the request was still going out (EPIPE or ECONNRESET on the send,
    ENOTCONN on Linux's or EINVAL on macOS's SHUT_WR) is an RST too, and
    what the server said before it is still read."""
    s = socket.create_connection(("127.0.0.1", port), timeout=CAP)
    got = b""
    reset = False
    try:
        try:
            s.sendall(raw)
            s.shutdown(socket.SHUT_WR)
        except socket.timeout:
            raise
        except OSError:
            reset = True
        deadline = time.monotonic() + CAP
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return got, "OPEN"
            s.settimeout(left)
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                return got, "OPEN"
            except ConnectionResetError:
                return got, "RST"
            if not chunk:
                return got, "RST" if reset else "EOF"
            got += chunk
    finally:
        s.close()


def fingerprint(seen):
    """Eight hex digits naming what the application saw besides the method
    and the body's length (the module docstring says what, and why)."""
    digest = hashlib.sha256()

    def field(raw):
        digest.update(b"%d:" % len(raw) + raw)

    field(bytes.fromhex(seen["request_uri"]))
    field(bytes.fromhex(seen["protocol"]))
    for name, value in seen["headers"]:
        field(bytes.fromhex(name).lower())
        field(bytes.fromhex(value))
    return digest.hexdigest()[:8]


def echoed(status, body):
    """The token for one final response: the request the echo names, or the
    status of anything else."""
    if status == "200":
        try:
            seen = json.loads(body)
            method = bytes.fromhex(seen["method"]).decode("latin-1")
            return "%s bl=%d h=%s" % (method, seen["body_len"], fingerprint(seen))
        except (ValueError, KeyError, TypeError):
            pass
    return status


def responses(stream):
    """A token for each response in `stream`, in order."""
    out = []
    i = 0
    while i < len(stream):
        end = stream.find(b"\r\n\r\n", i)
        if end < 0:
            out.append("PARTIAL")
            break
        lines = stream[i:end].decode("latin-1").split("\r\n")
        parts = lines[0].split(" ", 2)
        status = parts[1] if len(parts) > 1 else "?"
        length = None
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "content-length":
                try:
                    length = int(value.strip())
                except ValueError:
                    length = -1
        body_at = end + 4
        if status.startswith("1"):
            out.append(status)
            i = body_at
            continue
        if length is None:
            body, i = stream[body_at:], len(stream)
        elif length < 0 or body_at + length > len(stream):
            out.append("PARTIAL")
            break
        else:
            body, i = stream[body_at:body_at + length], body_at + length
        out.append(echoed(status, body))
    return out


def outcome(stream, ended):
    tokens = responses(stream) + ([] if ended == "EOF" else [ended])
    return tokens or ["NONE"]


def load_table():
    with open(TABLE, encoding="utf-8") as f:
        return json.load(f)


def write_table(table):
    """One case a line, in corpus order, so a re-freeze diffs by case."""
    about = ",\n".join("  " + json.dumps(line, ensure_ascii=False)
                        for line in table["about"])
    rows = ",\n".join("  %s: %s" % (json.dumps(name), json.dumps(row, ensure_ascii=False))
                      for name, row in table["cases"].items())
    with open(TABLE, "w", encoding="utf-8") as f:
        f.write('{\n "about": [\n%s\n ],\n "cases": {\n%s\n }\n}\n' % (about, rows))


def freeze(column, results):
    table = load_table()
    old = table["cases"]
    cases = {}
    for name, _raw in CASES:
        row = dict(old.get(name, {}))
        if name in results:
            row[column] = results[name]
        cases[name] = {k: row[k] for k in KEYS if k in row}
    table["cases"] = cases
    write_table(table)
    print("differential corpus: wrote `%s` for %d case(s) to %s"
          % (column, len(results), TABLE.name))


def differs(rows, name, got):
    """Print the case's line if the table disagrees with `got`; say whether."""
    want = rows.get(name, {}).get("ours")
    if want is None:
        print("MISSING %s: the table has no `ours` for it; the server answered %s"
              % (name, json.dumps(got)))
        return True
    if want != got:
        print("MISMATCH %s: the table says %s, the server answered %s"
              % (name, json.dumps(want), json.dumps(got)))
        return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("port", type=int)
    ap.add_argument("--only", metavar="NAME")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--print", action="store_true", dest="show")
    mode.add_argument("--freeze", nargs="?", const="ours", choices=COLUMNS)
    args = ap.parse_args()
    gate = not (args.show or args.freeze)

    phase("reading the corpus")
    names = [name for name, _raw in CASES]
    twice = sorted({n for n in names if names.count(n) > 1})
    if twice:
        fail("a case name is used twice: %s" % ", ".join(twice))
    if args.only and args.only not in names:
        fail("no case is named %r" % args.only)
    rows = load_table()["cases"] if gate else {}

    results = {}
    wrong = []
    still_open = []
    for name, raw in CASES:
        if args.only and name != args.only:
            continue
        phase("case " + name)
        got = outcome(*exchange(args.port, raw))
        results[name] = got
        if args.show:
            print("%-28s %s" % (name, json.dumps(got)))
        if not gate:
            continue
        if differs(rows, name, got):
            wrong.append(name)
        still_open = still_open + [name] if "OPEN" in got else []
        if len(still_open) == OPEN_RUN:
            fail("%d cases in a row were still open %g s after their request (%s): "
                 "the server has stopped closing a half-closed connection"
                 % (OPEN_RUN, CAP, ", ".join(still_open)))

    if args.show:
        return
    if args.freeze:
        phase("writing the table")
        freeze(args.freeze, results)
        return

    phase("comparing with the table")
    if args.only is None:
        for name in rows:
            if name not in results:
                print("STALE %s: a row of the table that names no case of the corpus" % name)
                wrong.append(name)
    if wrong:
        fail("%d of %d case(s) differ from %s: %s"
             % (len(wrong), len(results), TABLE.name, ", ".join(wrong)))

    phase("a plain GET after the corpus")
    after = outcome(*exchange(args.port, PLAIN_GET))
    if len(after) != 1 or not after[0].startswith("GET bl=0 "):
        fail("a plain GET after the corpus was answered %s, not served: the corpus "
             "left the server unable to serve" % json.dumps(after))
    print("differential corpus: %d case(s) answered as %s says, and a plain GET "
          "after them served" % (len(results), TABLE.name))


if __name__ == "__main__":
    main()
