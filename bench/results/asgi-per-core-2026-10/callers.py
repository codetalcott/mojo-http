import re, sys, collections
# For each thread, attribute samples of the named leaf syscalls to their nearest m0serve/python caller frame.
lines = open(sys.argv[1]).read().split('\n'); leaves = set(sys.argv[2].split(','))
start = next(i for i,l in enumerate(lines) if l.startswith('Call graph:'))
end = next(i for i,l in enumerate(lines[start:], start) if l.startswith('Total number in stack'))
res = collections.defaultdict(collections.Counter); thread=None; stack=[]
for l in lines[start+1:end]:
    m = re.match(r'^(\s*)([+!:| ]*)(\d+) (.*)$', l)
    if not m: continue
    depth=len(m.group(1))+len(m.group(2)); cnt=int(m.group(3)); rest=m.group(4).strip()
    if rest.startswith('Thread_'): thread=rest[:40]; stack=[]; continue
    fm = re.match(r'(.+?)\s+\(in ([^)]+)\)', rest); f = fm.group(1) if fm else rest; lib = fm.group(2) if fm else '?'
    while stack and stack[-1][0] >= depth: stack.pop()
    stack.append((depth, f, lib, cnt))
    if f in leaves:
        # nearest caller frames that are not libsystem
        callers = [s for s in stack[:-1] if not s[2].startswith('libsystem')]
        key = ' <- '.join(re.sub(r'\(.*','',c[1])[-60:] for c in callers[-2:][::-1])
        res[(thread,f)][key] += cnt
for (t,f),c in res.items():
    tot=sum(c.values())
    print(f"=== {t} :: {f}  ({tot} samples)")
    for k,v in c.most_common(6): print(f"   {v:5d}  {k}")
