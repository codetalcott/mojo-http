from lightbug_http.header import Header, HeaderKey, Headers
from lightbug_http.http.response import HTTPResponse


def OK(body: String, content_type: String = "text/plain") -> HTTPResponse:
    return HTTPResponse(
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, content_type)),
        body_bytes=body.as_bytes(),
    )


def BadRequest() -> HTTPResponse:
    return HTTPResponse(
        "Bad Request".as_bytes(),
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


def NotImplemented() -> HTTPResponse:
    """501: the request asks for something this server does not implement
    (RFC 9110 §15.6.2) -- the `CONNECT` method, or a transfer coding before
    the final `chunked`."""
    return HTTPResponse(
        "Not Implemented".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=501,
        status_text="Not Implemented",
    )


def InternalError() -> HTTPResponse:
    return HTTPResponse(
        "Failed to process request".as_bytes(),
        headers=Headers(Header(HeaderKey.CONTENT_TYPE, "text/plain")),
        status_code=500,
        status_text="Internal Server Error",
    )
