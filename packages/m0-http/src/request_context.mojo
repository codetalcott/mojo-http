"""Request context carrier for before/after hook data.

Lightweight struct that passes parsed request metadata from
before_request to after_response without re-parsing.
"""

from .content_negotiation import AcceptResult


struct RequestContext(Copyable, Movable):
    """Per-request context passed through the hook lifecycle."""
    var request_id: Int
    var accept: AcceptResult
    var start_ns: UInt
    var response_status: Int

    def __init__(out self, request_id: Int, accept: AcceptResult, start_ns: UInt):
        self.request_id = request_id
        self.accept = accept.copy()
        self.start_ns = start_ns
        self.response_status = 0

    def __init__(out self, *, copy: Self):
        self.request_id = copy.request_id
        self.accept = copy.accept.copy()
        self.start_ns = copy.start_ns
        self.response_status = copy.response_status

    def __init__(out self, *, deinit take: Self):
        self.request_id = take.request_id
        self.accept = take.accept^
        self.start_ns = take.start_ns
        self.response_status = take.response_status
