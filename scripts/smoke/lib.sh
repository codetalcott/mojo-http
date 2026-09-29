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
#   free_port               Print a TCP port that is free on IPv4 AND IPv6:
#                           `localhost` may reach an IPv6 listener first, and
#                           that would be somebody else's server. For a server
#                           whose number nothing outside the task depends on.
#                           A fixed port is shared machine-wide, and the
#                           listener sets SO_REUSEPORT, so two runs on one
#                           port both bind and split the connections.
#   fail [MSG]              Print MSG, then every $SMOKE_DIR/*.log under a
#                           `=== name ===` header, and exit 1. The message is
#                           the line before the first header on purpose:
#                           scripts/host_sabotage.py and
#                           scripts/notes_login_sabotage.py read it there to
#                           say which assertion caught a sabotage. Without
#                           MSG that line is whatever printed last -- a
#                           probe's own reason, after `probe || fail`.
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

_smoke_free_port='import errno, socket

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

for _ in range(100):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("", 0))
    port = s.getsockname()[1]
    ok = free_on_ipv6(port)
    s.close()
    if ok:
        print(port)
        break
else:
    raise SystemExit("free_port: no port was free on both IPv4 and IPv6")'

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
  python3 -S -c "$_smoke_free_port"
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
if command -v ps > /dev/null 2>&1; then _smoke_ps=1; else _smoke_ps=; fi
_smoke_running() {
  if [ -z "$_smoke_ps" ]; then
    kill -0 "$1" 2>/dev/null
    return
  fi
  case $(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ') in
    '' | Z*) return 1 ;;
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
