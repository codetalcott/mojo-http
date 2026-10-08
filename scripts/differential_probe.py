#!/usr/bin/env python3
"""The differential corpus on the wire, held to its frozen table (SPEC B25).

Every case of `differential_corpus.py` goes to the server on PORT on a
connection of its own: the bytes, then SHUT_WR, then everything the server
sends until it closes. The server is `apps/request_echo`, whose application
answers each request the loop hands it with a 200 naming what it saw, so a
response says whether the server parsed a request or refused one. What came
back is the case's OUTCOME, a list in the order it arrived:

    "GET bl=0"  a request the application saw: its method and body length
    "400"       any other response, by its status: a refusal, or a 100
    "PARTIAL"   a response cut short
    "RST"       the server reset the connection
    "OPEN"      the server had not closed it CAP seconds after the request
    "NONE"      no response at all, and the connection closed

The gate compares each outcome with the case's `ours` in
`differential_expected.json`, prints every case that differs with both
outcomes, and fails on any, as it does on a case the table has no row for
and on a row no case has. Every case ends in a close today, within
milliseconds of its request, so the cap is reached only by a server that
has stopped closing, and it is long enough that a slow runner never reaches
it otherwise.

`differential_corpus.py` says how the table grows: `--print` and `--freeze`
read the same outcomes from any server answering the echo's JSON, the two
references included.

usage:
    differential_probe.py PORT                    the gate
    differential_probe.py PORT --only NAME        one case
    differential_probe.py PORT --print            each case's outcome, nothing compared
    differential_probe.py PORT --freeze [COLUMN]  write the table's COLUMN (`ours`,
                                                  `h11` or `llhttp`) from PORT
"""
import argparse
import json
import socket
import time
from pathlib import Path

from differential_corpus import CASES
from probelib import fail, phase, stamp

stamp("differential_probe: FAIL")

TABLE = Path(__file__).resolve().parent / "differential_expected.json"
CAP = 3.0
COLUMNS = ("ours", "h11", "llhttp")
# A row's keys, in the order the table is written.
KEYS = COLUMNS + ("note", "known_divergence")


def exchange(port, raw):
    """What the server sent for `raw`, and how the connection ended: EOF,
    RST, or OPEN when it had not closed within CAP seconds."""
    s = socket.create_connection(("127.0.0.1", port), timeout=CAP)
    got = b""
    try:
        try:
            s.sendall(raw)
            s.shutdown(socket.SHUT_WR)
        except (BrokenPipeError, ConnectionResetError):
            pass  # refused before the last byte went: read what it said
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
                return got, "EOF"
            got += chunk
    finally:
        s.close()


def echoed(status, body):
    """The token for one final response: the request the echo names, or the
    status of anything else."""
    if status == "200":
        try:
            seen = json.loads(body)
            method = bytes.fromhex(seen["method"]).decode("latin-1")
            return "%s bl=%d" % (method, seen["body_len"])
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


def compare(results, whole):
    """Print each case the table disagrees with; the names, in corpus order."""
    rows = load_table()["cases"]
    wrong = []
    for name, got in results.items():
        want = rows.get(name, {}).get("ours")
        if want is None:
            print("MISSING %s: the table has no `ours` for it; the server answered %s"
                  % (name, json.dumps(got)))
            wrong.append(name)
        elif want != got:
            print("MISMATCH %s: the table says %s, the server answered %s"
                  % (name, json.dumps(want), json.dumps(got)))
            wrong.append(name)
    if whole:
        for name in rows:
            if name not in results:
                print("STALE %s: a row of the table that names no case of the corpus" % name)
                wrong.append(name)
    return wrong


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("port", type=int)
    ap.add_argument("--only", metavar="NAME")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--print", action="store_true", dest="show")
    mode.add_argument("--freeze", nargs="?", const="ours", choices=COLUMNS)
    args = ap.parse_args()

    phase("reading the corpus")
    names = [name for name, _raw in CASES]
    twice = sorted({n for n in names if names.count(n) > 1})
    if twice:
        fail("a case name is used twice: %s" % ", ".join(twice))
    if args.only and args.only not in names:
        fail("no case is named %r" % args.only)

    results = {}
    for name, raw in CASES:
        if args.only and name != args.only:
            continue
        phase("case " + name)
        results[name] = outcome(*exchange(args.port, raw))
        if args.show:
            print("%-28s %s" % (name, json.dumps(results[name])))

    phase("comparing with the table")
    if args.show:
        return
    if args.freeze:
        freeze(args.freeze, results)
        return
    wrong = compare(results, whole=args.only is None)
    if wrong:
        fail("%d of %d case(s) differ from %s: %s"
             % (len(wrong), len(results), TABLE.name, ", ".join(wrong)))
    print("differential corpus: %d case(s) answered as %s says" % (len(results), TABLE.name))


if __name__ == "__main__":
    main()
