"""A loop's connection count, as both servers read and report it.

m0serve (`--max-connections`, `M0_MAX_CONNECTIONS`) and the Mojo host take
the same count with the same bound, and a loop that fills says so in the
same words, each naming its own program. The words live here, below both,
so the two cannot drift: m0serve's `cli.mojo` and the host's `host.mojo`
build their `ServerConfig` notices from these (SPEC C20, C23, E43).
"""

from lightbug_http.server_config import ServerConfig


comptime MAX_CONNECTIONS = 65536
"""The most connections one loop holds. Its periodic sweeps walk every slot,
so more connections are more loops (`--workers`, `--threads`); m0serve's
`max-connections` rule and the host's refuse a count above it with 78."""


def connections_servable(count: Int) -> Bool:
    """Whether one loop can hold `count` connections: 1 to `MAX_CONNECTIONS`.

    A count outside it is refused before anything starts (78), never served;
    `AppConfig.server_config` passes on only a count this answers True for,
    so an application that builds a `Server` from it without the host's
    checks gets the default rather than a loop of no slots."""
    return count >= 1 and count <= MAX_CONNECTIONS


comptime _MORE = (
    "; raise --max-connections or M0_MAX_CONNECTIONS, or serve more loops"
    " (--workers, --threads)"
)
"""The fix both servers name: they take the same flags and variables."""


def stream_cap_notice(sc: ServerConfig, program: String) -> String:
    """The line a loop prints the first time a stream is answered 503
    because streams hold every slot but the reserve (SPEC C20)."""
    return String(
        program, ": a stream was answered 503: streams held ",
        sc.stream_limit(), " of this loop's ", sc.max_connections,
        " connections, and the last ", sc.stream_reserve(),
        " are kept for requests", _MORE,
    )


def slots_full_notice(sc: ServerConfig, reclaim: Bool, program: String) -> String:
    """The line a loop prints the first time a new connection finds every
    slot in use (SPEC C23), saying what the loop then does with this
    configuration: which connections it takes back -- one idle between
    requests for a second, while the idle timeout is on; one still sending
    its head after a second, while the header timeout is -- or, with
    `M0_RECLAIM=0` or both timeouts off, that it refuses each new one."""
    var taken = List[String]()
    if reclaim and sc.idle_timeout > 0:
        taken.append(String("one idle between requests for a second"))
    if reclaim and sc.header_read_timeout > 0:
        taken.append(String("one still sending its request after a second"))
    var what: String
    if len(taken) == 0:
        var why = String("M0_RECLAIM=0 takes none back")
        if reclaim:
            why = String("with the idle and header timeouts off none is taken back")
        what = why + ", so each new connection is refused until one closes"
    else:
        var which = String(taken[0])
        if len(taken) == 2:
            which = String(taken[0], ", or ", taken[1], ",")
        what = String(
            which, " is closed to admit the next, and a connection is"
            " refused only when none is",
        )
    return String(
        program, ": all ", sc.max_connections, " of a loop's connections"
        " were in use: ", what, _MORE,
    )
