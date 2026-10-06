import re, sys, collections
# Parse macOS `sample` call graphs: per thread, self samples by function and library.
lines = open(sys.argv[1]).read().split('\n')
start = next(i for i,l in enumerate(lines) if l.startswith('Call graph:'))
end = next(i for i,l in enumerate(lines[start:], start) if l.startswith('Total number in stack'))
pat = re.compile(r'^(\s*)[+!:|\s]*?(\d+)\s+(.*)$')
threads = []  # (name, total, selfcounts)
stack = []    # (depth, count, key, children_sum_ref)
cur = None
def flush():
    while stack:
        d,c,k,ch = stack.pop()
        cur[2][k] += c - ch[0]
for l in lines[start+1:end]:
    m = re.match(r'^(\s*)([+!:| ]*)(\d+) (.*)$', l)
    if not m: continue
    depth = len(m.group(1)) + len(m.group(2)); cnt = int(m.group(3)); rest = m.group(4).strip()
    if rest.startswith('Thread_'):
        if cur: flush(); threads.append(cur)
        cur = [rest[:60], cnt, collections.Counter()]; stack.clear(); continue
    fm = re.match(r'(.+?)\s+\(in ([^)]+)\)', rest)
    key = (fm.group(1)[:70], fm.group(2)) if fm else (rest[:70], '?')
    while stack and stack[-1][0] >= depth:
        d,c,k,ch = stack.pop(); cur[2][k] += c - ch[0]
    if stack: stack[-1][3][0] += cnt
    stack.append((depth, cnt, key, [0]))
if cur: flush(); threads.append(cur)
for name,total,sc in threads:
    if total < 50: continue
    bylib = collections.Counter()
    for (f,lib),c in sc.items(): bylib[lib]+=c
    print(f"=== {name}  total={total}")
    print("  by library:", ", ".join(f"{lib}={100*c/total:.1f}%" for lib,c in bylib.most_common(8)))
    for (f,lib),c in sc.most_common(int(sys.argv[2]) if len(sys.argv)>2 else 15):
        print(f"  {100*c/total:5.1f}%  {f}  [{lib}]")
