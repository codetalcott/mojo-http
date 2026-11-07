"""The asyncio executor's tables, without an interpreter or a thread.

`ExecutorState` keeps two kinds of state. What a JOB needs from its request
crossing into Python until its one completion -- the method and path
`after_response` reads, and the 101 held for a WebSocket handshake until the
application accepts -- lives in the pool's job entries (`OffloadPool.
job_entry`), of which there are at most `OFFLOAD_MAX_INFLIGHT`. What a
STREAM needs after its head -- its generation, and whether it lost a frame
-- outlives the job and stays a slot. Sized a slot, the job half was 344 B
of every connection slot for a few hundred jobs (#682). The port's own
lookups are exercised on the wire by `smoke-asgi`; these pin the tables'
sizes and what a slot with no job reads.
"""

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from lightbug_http.http import OK
from lightbug_http.offload import OFFLOAD_MAX_INFLIGHT

from src.asgi_executor import ExecutorState, _held_101, _job_method, _job_path


def test_a_jobs_state_is_kept_per_job_and_a_streams_per_slot() raises:
    """4096 slots, 256 job entries: the method, path and held 101 are 256
    long and the generation and lost flag 4096; a state built without the
    pool's count sizes its job half as a pool of that many slots does.

    covers: C27
    """
    var st = ExecutorState(0, 4096, 256)
    assert_equal(len(st.methods), 256)
    assert_equal(len(st.paths), 256)
    assert_equal(len(st.pending_101), 256)
    assert_equal(len(st.gens), 4096)
    assert_equal(len(st.lost), 4096)
    var many = ExecutorState(-1, 4096)
    assert_equal(len(many.methods), OFFLOAD_MAX_INFLIGHT)
    assert_equal(len(many.gens), 4096)
    var few = ExecutorState(-1, 8)
    assert_equal(len(few.methods), 8)
    assert_equal(len(few.lost), 8)


def test_a_slot_with_no_job_reads_no_method_and_holds_no_101() raises:
    """An event for a slot whose job is not in flight finds no entry (-1):
    it reads an empty method and path and no held 101. A -1 is no index --
    `List` refuses it with a bounds assertion, which would end the process
    on a late event from a task whose job had completed.

    covers: C27
    """
    var st = ExecutorState(0, 16, 16)
    st.methods[15] = String("HEAD")
    st.paths[15] = String("/last")
    st.pending_101[15] = OK(String("held"))
    assert_equal(_job_method(st, 15), "HEAD")
    assert_equal(_job_path(st, 15), "/last")
    assert_true(_held_101(st, 15))
    assert_equal(_job_method(st, -1), "")
    assert_equal(_job_path(st, -1), "")
    assert_false(_held_101(st, -1), "a slot with no job read the last entry's 101")
    assert_false(_held_101(st, 3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
