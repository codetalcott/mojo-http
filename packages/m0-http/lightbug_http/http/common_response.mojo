from lightbug_http.cookie import Cookie, ResponseCookieJar
from lightbug_http.header import Header, HeaderKey, Headers
from lightbug_http.http.response import HTTPResponse
from lightbug_http.io.bytes import Bytes


def OK(body: String, content_type: String = "text/plain") -> HTTPResponse:
    return HTTPResponse(
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, content_type)),
        body_bytes=body.as_bytes(),
    )


def OK(body: Bytes, content_type: String = "text/plain") -> HTTPResponse:
    return HTTPResponse(
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, content_type)),
        body_bytes=body,
    )


def OK(body: Bytes, content_type: String, content_encoding: String) -> HTTPResponse:
    return HTTPResponse(
        headers=Headers(
            Header(HeaderKey.CONTENT_TYPE, content_type),
            Header(HeaderKey.CONTENT_ENCODING, content_encoding),
        ),
        body_bytes=body,
    )


def SeeOther(location: String, content_type: String, var cookies: List[Cookie] = []) -> HTTPResponse:
    return HTTPResponse(
        "See Other".as_bytes(),
        cookies=ResponseCookieJar(cookies^),
        headers=Headers(
            Header(HeaderKey.LOCATION, location),
            Header(HeaderKey.CONTENT_TYPE, content_type),
        ),
        status_code=303,
        status_text="See Other",
    )


def BadRequest() -> HTTPResponse:
    return HTTPResponse(
        "Bad Request".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=400,
        status_text="Bad Request",
    )


def BadRequest(message: String) -> HTTPResponse:
    """Bad Request with a specific error message.

    Args:
        message: Specific explanation of what went wrong with the request.
    """
    return HTTPResponse(
        String("Bad Request: ", message).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=400,
        status_text="Bad Request",
    )


def NotFound(path: String) -> HTTPResponse:
    return HTTPResponse(
        body_bytes=String("path ", path, " not found").as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=404,
        status_text="Not Found",
    )


def PayloadTooLarge() -> HTTPResponse:
    return HTTPResponse(
        "Payload Too Large".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=413,
        status_text="Payload Too Large",
    )


def URITooLong() -> HTTPResponse:
    return HTTPResponse(
        "URI Too Long".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=414,
        status_text="URI Too Long",
    )


def RequestTimeout() -> HTTPResponse:
    return HTTPResponse(
        "Request Timeout".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=408,
        status_text="Request Timeout",
    )


def HeadersTooLarge() -> HTTPResponse:
    return HTTPResponse(
        "Request Header Fields Too Large".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=431,
        status_text="Request Header Fields Too Large",
    )


def StreamingUnsupported() -> HTTPResponse:
    """409 for a held-stream response on the blocking accept loop.

    Only the non-blocking event loop assigns `req.slot_id`, drains the
    outbox, and keeps held connections open; the blocking loop can do none
    of that. Before this response existed it would write an `sse_streaming`
    body as a one-shot and close -- a silent degradation issue #118 caught:
    the client saw one frame and an EOF, and nothing anywhere said why.
    """
    return HTTPResponse(
        (
            "streaming is not available on this server loop: SSE holds and"
            " WebSocket upgrades need the event loop. Serve with"
            " listen_and_serve_nonblocking instead of listen_and_serve.\n"
        ).as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=409,
        status_text="Conflict",
    )


def InternalError() -> HTTPResponse:
    return HTTPResponse(
        "Failed to process request".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=500,
        status_text="Internal Server Error",
    )
