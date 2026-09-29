# The shared harness of the inline smoke tasks in pyproject.toml.
#
# A task sources it before anything else:
#
#     . scripts/smoke/lib.sh
#     port=$(free_port)
#     spawn hello.log env M0_PORT=$port mojo run ... apps/hello/server.mojo
#     wait_ready http://localhost:$port/health $pid
#     python3 scripts/x_probe.py $port || fail 'the x probe failed'
#
# POSIX sh, because poe runs a shell task under `sh`: dash on the Linux
# runner, bash's POSIX mode on macOS. So no `local`, arrays, `[[`,
# `pipefail` or `$'..'`, and a group is signalled as `kill -TERM "-$pgid"`:
# dash's kill refuses both `--` and `-s TERM` in front of a negative pid.
# `uv run poe check-task-shells` parses every task body under dash.
#
# Sourcing it makes $SMOKE_DIR, a fresh directory for everything the task
# writes -- logs, headers, captured streams, binaries, databases -- in place
# of the repo root, and arms the cleanup below. What it defines:
#
#   spawn LOG CMD [ARG...]  Start CMD in the background, as the leader of a
#                           process group of its own, with its output in
#                           $SMOKE_DIR/LOG, and set $pid. Environment goes
#                           INSIDE the command (`spawn x.log env M0_WORKERS=2
#                           cmd`), never in front of spawn: bash's POSIX mode
#                           keeps an assignment made before a function call
#                           after the function returns, so every later
#                           command would inherit it on macOS alone.
#   wait_ready URL PID [S]  Poll URL until it answers 2xx. Fails at once when
#                           PID has exited -- a server that crashed on
#                           startup is reported with its log, not after the
#                           timeout -- and after S seconds (default 60, the
#                           budget the old `curl --retry 20 --retry-delay 3`
#                           spent) when it never answers.
#   stop PID                TERM PID's whole process group -- a supervisor's
#                           forked workers included, which a `kill $pid`
#                           never reached -- wait up to 10 s for all of it
#                           to exit, KILL whatever is left, and reap PID.
#                           Returns PID's exit status.
#   free_port [N]           Print a TCP port that is free on IPv4 AND IPv6:
#                           `localhost` may reach an IPv6 listener first, and
#                           that would be somebody else's server. For a server
#                           whose number nothing outside the task depends on:
#                           a fixed port is shared machine-wide, so a second
#                           run on it fails to bind. With N, the first of N
#                           consecutive ports that all are, for a probe that
#                           serves one shape per port from the one it is given
#                           upward. The run is picked at random between 10000
#                           and the kernel's ephemeral range, never inside it
#                           (below).
#   fail [MSG]              Print MSG, then every $SMOKE_DIR/*.log under a
#                           `=== name ===` header, and exit 1. The message is
#                           the line before the first header on purpose:
#                           scripts/host_sabotage.py and
#                           scripts/notes_login_sabotage.py read it there to
#                           say which assertion caught a sabotage. Without
#                           MSG that line is whatever printed last -- a
#                           probe's own reason, after `probe || fail`.
#
# Why free_port stays below the ephemeral range: every connect() and bind(0)
# on the machine takes its port from that range, and macOS hands them out in
# sequence, so the ports just above one that bind(0) returned go to the next
# connections anyone makes, the probe's own included. A socket on the port
# then refuses the server's bind: on Linux any socket, on macOS (past
# m0serve's SO_REUSEADDR) one owned by another user. That was a rare
# "address in use" in smoke-child-publish on the macOS runner. Nothing is
# handed out below the range, so a run there is taken only by a bind.
#
# On exit, however the task ends, every group spawn started and stop did not
# is stopped the same way, and $SMOKE_DIR is removed -- unless the task
# failed, when its *.log files are kept (the rest, binaries included, is
# not) so CI can upload them from $RUNNER_TEMP. On SIGINT, SIGTERM or SIGHUP
# the groups are killed without the grace period: poe answers a Ctrl-C by
# signalling the task's own group, which reaches nothing spawn started, and
# SIGKILLs that group 1.6 s later (at once, for its own SIGTERM), so a
# graceful drain there would be cut short and leave the servers running.
# A signal that arrives while the exit trap is draining cuts its grace the
# same way, rather than ending the shell with groups still unreaped.

_smoke_pids=
_smoke_grace=10
_smoke_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
SMOKE_DIR=$(mktemp -d "${_smoke_root%/}/m0-smoke.XXXXXX") || {
  echo "scripts/smoke/lib.sh: could not make a directory under $_smoke_root"
  exit 1
}

# setpgid, then exec: the command keeps the pid spawn reports and leads a
# group of its own. Python ignores SIGPIPE and SIGXFSZ, and an ignored
# signal survives exec, so both go back to the default the shell would have
# left. -S: nothing from site-packages runs in front of a server.
_smoke_leader='import os, signal, sys
os.setpgid(0, 0)
for name in ("SIGPIPE", "SIGXFSZ"):
    if hasattr(signal, name):
        signal.signal(getattr(signal, name), signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])'

# The run is drawn from bases FLOOR to where the ephemeral range starts less
# N, at random so two tasks at once rarely draw the same one. A selftest may
# pin the bases with two more arguments; free_port passes only its first.
_smoke_free_port='import errno, random, socket, subprocess, sys

FLOOR = 10000  # below it sit the ports fixed-port services take

def ephemeral_start():
    """Where the ports connect() and bind(0) hand out begin."""
    try:
        with open("/proc/sys/net/ipv4/ip_local_port_range") as f:
            return int(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        pass
    for exe in ("sysctl", "/usr/sbin/sysctl"):
        try:
            out = subprocess.run([exe, "-n", "net.inet.ip.portrange.first"],
                                 capture_output=True, text=True, timeout=10)
            return int(out.stdout.split()[0])
        except (OSError, ValueError, IndexError, subprocess.SubprocessError):
            pass
    return 32768  # neither said: the lower of the Linux and macOS defaults

def free_on_ipv6(port):
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    except OSError:
        return True  # no IPv6 here, so nobody can answer localhost on it
    try:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.bind(("::", port))
    except OSError as e:
        return e.errno != errno.EADDRINUSE  # anything else cannot be held
    finally:
        s.close()
    return True

def free_on_ipv4(port):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("", port))
    except OSError:
        return False
    finally:
        s.close()
    return True

arg = sys.argv[1] if len(sys.argv) > 1 else "1"
if not arg.isdigit() or int(arg) < 1:
    raise SystemExit("free_port: usage: free_port [N], N a count of ports")
count = int(arg)
first = ephemeral_start()
low, high = FLOOR, first - count
if len(sys.argv) > 3:
    low, high = int(sys.argv[2]), int(sys.argv[3])
if high < low:
    raise SystemExit("free_port: the ephemeral range starts at %d, leaving no run of %d "
                     "ports between %d and it" % (first, count, FLOOR))
for port in random.sample(range(low, high + 1), min(100, high - low + 1)):
    if all(free_on_ipv4(p) and free_on_ipv6(p) for p in range(port, port + count)):
        print(port)
        break
else:
    raise SystemExit("free_port: no run of %d ports was free on both IPv4 and IPv6" % count)'

spawn() {
  [ $# -ge 2 ] || fail "spawn: usage: spawn LOG COMMAND [ARG...]"
  _smoke_last_log=$1
  shift
  python3 -S -c "$_smoke_leader" "$@" < /dev/null > "$SMOKE_DIR/$_smoke_last_log" 2>&1 &
  pid=$!
  _smoke_last_pid=$pid
  _smoke_pids="$_smoke_pids $pid"
}

free_port() {
  python3 -S -c "$_smoke_free_port" "${1:-1}"
}

fail() {
  [ $# -eq 0 ] || printf '%s\n' "$*"
  for _smoke_f in "$SMOKE_DIR"/*.log; do
    [ -f "$_smoke_f" ] || continue
    echo "=== ${_smoke_f##*/} ==="
    cat "$_smoke_f"
    # A log that does not end in a newline would swallow the next header.
    [ -z "$(tail -c 1 "$_smoke_f")" ] || echo
  done
  exit 1
}

# Alive, and not a zombie: an exited child stays in the process table until
# it is reaped, and dash reaps only while it waits for something. Where
# there is no `ps` (a minimal container), `kill -0`, which counts a zombie.
# `kill -0` says whether the process is there at all, and `ps` only whether
# it is a zombie: a `ps` that answers nothing has not said "gone". An
# interrupt reaches the task's whole group, `ps` among it, and an empty
# answer read as "exited" sent the reap to `wait` on a live server -- for
# as long as it lived, when it ignored TERM.
if command -v ps > /dev/null 2>&1; then _smoke_ps=1; else _smoke_ps=; fi
_smoke_running() {
  kill -0 "$1" 2>/dev/null || return 1
  [ -n "$_smoke_ps" ] || return 0
  case $(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ') in
    Z*) return 1 ;;
  esac
  return 0
}

# The failure names the log of the server waited on, which is what says
# which phase of a task never came up.
wait_ready() {
  _smoke_url=$1
  _smoke_wpid=$2
  _smoke_wait=${3:-60}
  _smoke_who="the server (pid $_smoke_wpid)"
  [ "$_smoke_wpid" != "${_smoke_last_pid:-}" ] \
    || _smoke_who="the server logging to $_smoke_last_log (pid $_smoke_wpid)"
  _smoke_end=$(($(date +%s) + _smoke_wait))
  until curl --silent --fail --max-time 5 --output /dev/null "$_smoke_url"; do
    _smoke_running "$_smoke_wpid" \
      || fail "$_smoke_who exited before $_smoke_url answered"
    [ "$(date +%s)" -lt "$_smoke_end" ] \
      || fail "$_smoke_who did not answer $_smoke_url within ${_smoke_wait}s"
    sleep 0.2
  done
}

# CONT first: a stopped process holds a TERM until it runs again. The group
# kill fails only in the moment before the leader has called setpgid, when
# the pid is still in the shell's own group, so the fallback signals the pid.
# The grace ends when the whole group has gone, not the leader: a
# supervisor can exit while its workers are still draining. The leader is
# reaped as soon as it exits, so its zombie does not keep the group alive.
_smoke_reap() {
  kill -CONT "-$1" 2>/dev/null
  kill -TERM "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null
  _smoke_rs=
  _smoke_n=$((_smoke_grace * 10))
  while [ "$_smoke_n" -gt 0 ] && [ "$_smoke_grace" -gt 0 ]; do
    if [ -z "$_smoke_rs" ] && ! _smoke_running "$1"; then
      wait "$1" 2>/dev/null
      _smoke_rs=$?
    fi
    [ -n "$_smoke_rs" ] && ! kill -0 "-$1" 2>/dev/null && break
    sleep 0.1
    _smoke_n=$((_smoke_n - 1))
  done
  kill -KILL "-$1" 2>/dev/null || kill -KILL "$1" 2>/dev/null
  if [ -z "$_smoke_rs" ]; then
    wait "$1" 2>/dev/null
    _smoke_rs=$?
  fi
  return "$_smoke_rs"
}

stop() {
  _smoke_status=0
  _smoke_reap "$1" || _smoke_status=$?
  _smoke_left=
  for _smoke_q in $_smoke_pids; do
    [ "$_smoke_q" = "$1" ] || _smoke_left="$_smoke_left $_smoke_q"
  done
  _smoke_pids=$_smoke_left
  return "$_smoke_status"
}

_smoke_exit() {
  _smoke_rc=$?
  # A signal while the groups drain ends the grace, not the shell: an exit
  # from inside this trap would leave every group not yet reaped running.
  trap '_smoke_grace=0' INT TERM HUP
  for _smoke_q in $_smoke_pids; do
    _smoke_reap "$_smoke_q" || :
  done
  _smoke_pids=
  if [ "$_smoke_rc" -eq 0 ]; then
    rm -rf "$SMOKE_DIR"
  else
    find "$SMOKE_DIR" -type f ! -name '*.log' -exec rm -f {} + 2>/dev/null
  fi
}

trap _smoke_exit EXIT
trap '_smoke_grace=0; exit 130' INT
trap '_smoke_grace=0; exit 143' TERM
trap '_smoke_grace=0; exit 129' HUP
