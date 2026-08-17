from lightbug_http import Server, HTTPService, HTTPRequest, HTTPResponse, OK


@fieldwise_init
struct HelloHandler(HTTPService):
    def func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        if req.uri.request_uri == "/health":
            return OK('{"status":"ok"}', "application/json")
        return OK("hello from m0", "text/plain")

    def before_request(mut self, req: HTTPRequest) -> Optional[HTTPResponse]:
        return None

    def after_response(
        mut self, req_method: String, req_path: String, mut resp: HTTPResponse
    ):
        pass

    def sse_drain_slot(mut self, slot: Int) -> List[UInt8]:
        return List[UInt8]()

    def sse_is_streaming(self, slot: Int) -> Bool:
        return False

    def sse_slot_disconnected(mut self, slot: Int):
        pass

    def sse_peer_frame(mut self, url: String, event_id: Int, frame: List[UInt8]):
        pass

    def tick(mut self, now_ms: Int):
        pass

    def ws_message(mut self, slot: Int, opcode: Int, payload: List[UInt8]):
        pass


def main() raises:
    print("Starting hello server on 0.0.0.0:8080")
    var server = Server()
    var handler = HelloHandler()
    server.listen_and_serve("0.0.0.0:8080", handler)
