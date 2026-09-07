"""Per-thread on-CPU self time by leaf symbol from an xctrace export.

    xctrace export --input NAME.trace \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > NAME.xml
    python3 xctrace_report.py NAME.xml

Regex-based on purpose: Mojo symbol names put raw & < > inside the export's
name= attributes, so ElementTree refuses the file. Prints, per thread with
>= 100 samples, the top self-time symbols and inclusive shares for KEYS.
Scale a share to microseconds with (thread %cpu / rps) from bench_threads.
"""
import sys, re, collections
import xml.etree.ElementTree as ET

def short(name):
    name = re.sub(r"\(.*$", "", name)          # drop the parameter list
    name = re.sub(r"\[.*$", "", name)          # drop generic params
    return name[:70]

def load(path):
    """Regex-based: the export's attribute values carry unescaped characters."""
    text = open(path, errors="replace").read()
    ids = {}
    out = []
    row_re = re.compile(r"<row>(.*?)</row>", re.S)
    for m in row_re.finditer(text):
        r = m.group(1)
        th = re.search(r'<thread (id|ref)="(\d+)"(?: fmt="([^"]*)")?', r)
        if th.group(1) == "id": ids[("thread", th.group(2))] = th.group(3); tname = th.group(3)
        else: tname = ids[("thread", th.group(2))]
        st = re.search(r'<thread-state (id|ref)="(\d+)"(?: fmt="([^"]*)")?', r)
        if st:
            if st.group(1) == "id": ids[("state", st.group(2))] = st.group(3); state = st.group(3)
            else: state = ids[("state", st.group(2))]
        else: state = "?"
        tb = re.search(r'<tagged-backtrace (id|ref)="(\d+)"', r)
        if not tb: continue
        if tb.group(1) == "ref":
            frames = ids[("tb", tb.group(2))]
        else:
            body = r[tb.end():]
            bt = re.search(r'<backtrace (id|ref)="(\d+)"', body)
            if bt and bt.group(1) == "ref":
                frames = ids[("bt", bt.group(2))]
            else:
                frames = []
                for fm in re.finditer(r'<frame (id|ref)="(\d+)"(?: name="([^"]*)" addr="[^"]*")?(?:>\s*<binary (?:id="(\d+)" name="([^"]*)"|ref="(\d+)"))?', body):
                    if fm.group(1) == "ref":
                        frames.append(ids[("frame", fm.group(2))]); continue
                    lib = ""
                    if fm.group(4): ids[("binary", fm.group(4))] = fm.group(5); lib = fm.group(5)
                    elif fm.group(6): lib = ids.get(("binary", fm.group(6)), "")
                    val = (fm.group(3) or "?", lib)
                    ids[("frame", fm.group(2))] = val
                    frames.append(val)
                if bt: ids[("bt", bt.group(2))] = frames
            ids[("tb", tb.group(2))] = frames
        out.append((tname, state, frames))
    return out

KEYS = ["kevent", "__recvfrom", "__sendto", "writev", "__write", "__read", "parse_request_headers", "parse_headers", "scan_token", "encode_into", "_finish_response", "_service_completions", "drain_completions", "_handle_read_headers", "_process_request", "park_request", "take_response", "from_parsed", "_drain_pipelined", "PyEval_SaveThread", "PyEval_RestoreThread", "build_environ", "PyObject_Call", "build_response", "read_head", "body_bytes", "_PyEval_EvalFrameDefault", "next_job", "complete", "swtch", "semaphore", "psynch", "ulock", "_alloc_bytes", "free", "malloc", "tc_", "memcpy", "memmove", "_run_pass", "_after_send", "prepare_for_new_request", "HTTPRequest", "HTTPResponse", "Headers"]

def report(path, top=18):
    samples = load(path)
    by_thread = collections.defaultdict(list)
    for t, st, fr in samples: by_thread[t].append((st, fr))
    for t, rows in sorted(by_thread.items(), key=lambda kv: -len(kv[1])):
        if len(rows) < 100: continue
        n = len(rows)
        print(f"== {t[:70]}  on-cpu samples={n}")
        selfc = collections.Counter(); incl = collections.Counter()
        for st, fr in rows:
            if fr: selfc[f"{short(fr[0][0])} [{fr[0][1]}]"] += 1
            seen = set()
            for name, lib in fr:
                for k in KEYS:
                    if k in name and k not in seen:
                        incl[k] += 1; seen.add(k)
        for s, c in selfc.most_common(top):
            print(f"   {100*c/n:5.1f}%  {s}")
        print("  inclusive:", ", ".join(f"{k}={100*incl[k]/n:.1f}" for k in KEYS if incl[k]))
if __name__ == "__main__":
    for p in sys.argv[1:]:
        print("#####", p.split("/")[-1]); report(p)
