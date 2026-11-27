#!/usr/bin/env python3
"""Build arm C and the sabotages from a mojo-http checkout.

    build.py MOJO_HTTP OUTDIR

Each sabotage is a copy of apps/table_notes/server.mojo with one rule
broken; an anchor that is not found exactly once is an error, so a sabotage
can never be silently empty.
"""
import os
import subprocess
import sys

SABOTAGES = {
    "C": [],
    # S1: the comparison always matches.
    "S1": [(
        "        if len(differ) > 0 and why.byte_length() == 0:\n",
        "        differ = List[Seen]()\n        if len(differ) > 0 and why.byte_length() == 0:\n",
    )],
    # S2: a stamped update leaves the copy where it was.
    "S2": [(
        "    UPDATE notes_seen SET title = new.title WHERE id = new.id AND old.id IS new.id;\n",
        "",
    )],
    # S3: no raise at startup.
    "S3": [("        self.raise_floor(String(\"startup\"))\n", "")],
    # S4: a restore found by the head alone, not by the schema version.
    "S4": [(
        "        var restored = head < self.highest or (self.schema >= 0 and schema != self.schema)\n",
        "        var restored = head < self.highest\n",
    )],
    # G1-G3, one per finding of the merge of the rows and their copies
    # (2026-11-27). G1: a copy whose row is gone is ignored.
    "G1": [("        for ref d in gone:\n", "        gone = List[Seen]()\n        for ref d in gone:\n")],
    # G2: a row with no copy at its id is counted as matched.
    "G2": [("                differ.append(Seen(id, True, title^, False, String()))\n", "                pass\n")],
    # G3: a row and its copy are never compared.
    "G3": [("                if copy != title:\n", "                if False:\n")],
}


def main():
    repo, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    src = open(os.path.join(repo, "apps/table_notes/server.mojo")).read()
    for name, edits in SABOTAGES.items():
        s = src
        for old, new in edits:
            if s.count(old) != 1:
                raise SystemExit(f"{name}: anchor found {s.count(old)} times: {old[:60]!r}")
            s = s.replace(old, new)
        path = os.path.join(out, f"server_{name}.mojo")
        open(path, "w").write(s)
        cmd = ["uv", "run", "mojo", "build", "-I", "packages/m0-core/", "-I", "packages/m0-http/",
               "-I", "packages/m0-sqlite/", path, "-o", os.path.join(out, f"table_notes_{name}")]
        r = subprocess.run(cmd, cwd=repo, capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit(f"{name}: build failed\n{r.stdout}\n{r.stderr}")
        print(f"built {name}")


if __name__ == "__main__":
    main()
