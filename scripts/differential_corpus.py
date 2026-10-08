"""The differential corpus: request byte strings that probe framing and field
parsing, each sent on a connection of its own (SPEC B25).

Each case is `(name, bytes)`, and a name is never reused. Hosts are present
unless the case is about `Host`. The corpus began as the lightbug fork
review's D0 run (2026-10-07), which sent these cases to the fork, to h11 0.16
and to Node 24's llhttp, and compared what each server handed its
application. Every disagreement was triaged there, and the fork's answers
were fixed where it was wrong (SPEC B12-B24). What the fork answers now is
frozen, case by case, in `differential_expected.json` beside this file, and
`poe smoke-differential` holds the server to it on every pull request.

The references are not CI dependencies: they are how the table grows.

Adding a case
-------------
Add it to CASES, then re-freeze every column and read what moved:

    uv run poe freeze-differential
    git diff scripts/differential_expected.json

The task builds `apps/request_echo` and starts it and the two reference
echoes beside this file, each on a free port: `differential_echo_h11.py`
(h11 0.16, in the dev venv) and `differential_echo_node.js` (Node's llhttp,
when `node` is on PATH). It writes the echo's answers as `ours` and theirs as
`h11` and `llhttp`, and keeps every note. One server can be asked by hand
too, on a port of your choosing:

    python3 scripts/differential_probe.py PORT --print --only NAME

Then read the new row. Where `ours` differs from both references, say why in
its `note`, or, when the answer looks wrong and is frozen anyway until a fix
lands, name the record in its `known_divergence`. A change that moves an
answer on purpose re-freezes the same way, in the change that moves it.
"""

G = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"


def post(cl_line: bytes, body: bytes) -> bytes:
    return b"POST / HTTP/1.1\r\nHost: x\r\n" + cl_line + b"\r\n\r\n" + body


def te(te_value: bytes, body: bytes, version: bytes = b"HTTP/1.1") -> bytes:
    return b"POST / " + version + b"\r\nHost: x\r\nTransfer-Encoding: " + te_value + b"\r\n\r\n" + body


CH = b"5\r\nhello\r\n0\r\n\r\n"

CASES = [
    # --- line endings ---------------------------------------------------
    ("crlf_basic", G),
    ("lf_everywhere", b"GET / HTTP/1.1\nHost: x\n\n"),
    ("lf_request_line", b"GET / HTTP/1.1\nHost: x\r\n\r\n"),
    ("lf_field_line", b"GET / HTTP/1.1\r\nHost: x\nX: y\r\n\r\n"),
    ("lf_blank_line", b"GET / HTTP/1.1\r\nHost: x\r\n\n"),
    ("lf_blank_then_request", b"GET /a HTTP/1.1\r\nHost: x\r\n\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("lf_blank_then_cl", b"POST /a HTTP/1.1\r\nHost: x\r\n\nContent-Length: 33\r\n\r\n" + b"GET /b HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("bare_cr_in_field", b"GET / HTTP/1.1\r\nHost: x\rX: y\r\n\r\n"),
    ("bare_cr_request_line", b"GET / HTTP/1.1\rHost: x\r\n\r\n"),
    ("cr_cr_lf", b"GET / HTTP/1.1\r\r\nHost: x\r\n\r\n"),
    ("leading_crlf", b"\r\n" + G),
    ("leading_lf", b"\n" + G),
    ("leading_two_crlf", b"\r\n\r\n" + G),
    ("only_crlfcrlf", b"\r\n\r\n"),
    # --- whitespace, folding, names -------------------------------------
    ("ws_before_colon", b"GET / HTTP/1.1\r\nHost : x\r\n\r\n"),
    ("tab_before_colon", b"GET / HTTP/1.1\r\nHost\t: x\r\n\r\n"),
    ("ws_before_colon_cl", b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length : 5\r\n\r\nhello"),
    ("obs_fold", b"GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n 2\r\n\r\n"),
    ("obs_fold_tab", b"GET / HTTP/1.1\r\nHost: x\r\nX-A: 1\r\n\t2\r\n\r\n"),
    ("fold_first_line", b"GET / HTTP/1.1\r\n Host: x\r\n\r\n"),
    ("fold_te", b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n ,chunked\r\n\r\n" + CH),
    ("space_in_name", b"GET / HTTP/1.1\r\nHost: x\r\nX A: 1\r\n\r\n"),
    ("empty_name", b"GET / HTTP/1.1\r\nHost: x\r\n: 1\r\n\r\n"),
    ("no_colon", b"GET / HTTP/1.1\r\nHost: x\r\nXY\r\n\r\n"),
    ("value_trailing_ws", b"GET / HTTP/1.1\r\nHost: x\r\nX: y \t\r\n\r\n"),
    ("nul_in_value", b"GET / HTTP/1.1\r\nHost: x\r\nX: a\x00b\r\n\r\n"),
    ("nul_in_name", b"GET / HTTP/1.1\r\nHost: x\r\nX\x00: a\r\n\r\n"),
    ("ctl_in_value", b"GET / HTTP/1.1\r\nHost: x\r\nX: a\x01b\r\n\r\n"),
    ("del_in_value", b"GET / HTTP/1.1\r\nHost: x\r\nX: a\x7fb\r\n\r\n"),
    ("obs_text_in_value", b"GET / HTTP/1.1\r\nHost: x\r\nX: caf\xe9\r\n\r\n"),
    ("utf8_in_name", b"GET / HTTP/1.1\r\nHost: x\r\nX\xc3\xa9: a\r\n\r\n"),
    ("vt_in_value", b"GET / HTTP/1.1\r\nHost: x\r\nX: a\x0bb\r\n\r\n"),
    # --- request line ---------------------------------------------------
    ("double_space", b"GET  / HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("tab_separators", b"GET\t/\tHTTP/1.1\r\nHost: x\r\n\r\n"),
    ("trailing_space_version", b"GET / HTTP/1.1 \r\nHost: x\r\n\r\n"),
    ("lowercase_method", b"get / HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("bad_method_char", b"G@T / HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("missing_version", b"GET /\r\nHost: x\r\n\r\n"),
    ("http09", b"GET /\r\n"),
    ("http10_no_host", b"GET / HTTP/1.0\r\n\r\n"),
    ("http12_no_host", b"GET / HTTP/1.2\r\n\r\n"),
    ("http12_host", b"GET / HTTP/1.2\r\nHost: x\r\n\r\n"),
    ("http20", b"GET / HTTP/2.0\r\nHost: x\r\n\r\n"),
    ("http110", b"GET / HTTP/1.10\r\nHost: x\r\n\r\n"),
    ("lower_http", b"GET / http/1.1\r\nHost: x\r\n\r\n"),
    ("http_leading_zero", b"GET / HTTP/01.1\r\nHost: x\r\n\r\n"),
    ("absolute_form", b"GET http://h/p?q=1 HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("absolute_form_upper", b"GET HTTP://h/p HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("absolute_empty_authority", b"GET http:///p HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("absolute_userinfo", b"GET http://u:p@h/p HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("absolute_https", b"GET https://h/p HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("authority_form_get", b"GET h:80 HTTP/1.1\r\nHost: h\r\n\r\n"),
    ("connect", b"CONNECT h:443 HTTP/1.1\r\nHost: h:443\r\n\r\n"),
    ("asterisk_options", b"OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("asterisk_get", b"GET * HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("target_fragment", b"GET /p#frag HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("target_high_bytes", b"GET /caf\xe9 HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("target_space", b"GET /a b HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("target_ctl", b"GET /a\x01b HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("empty_target", b"GET  HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("target_relative", b"GET p HTTP/1.1\r\nHost: x\r\n\r\n"),
    # --- Host -----------------------------------------------------------
    ("no_host_11", b"GET / HTTP/1.1\r\n\r\n"),
    ("two_host", b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
    ("two_host_case", b"GET / HTTP/1.1\r\nHost: a\r\nHOST: b\r\n\r\n"),
    ("empty_host", b"GET / HTTP/1.1\r\nHost:\r\n\r\n"),
    ("host_with_space", b"GET / HTTP/1.1\r\nHost: a b\r\n\r\n"),
    ("host_with_userinfo", b"GET / HTTP/1.1\r\nHost: u@a\r\n\r\n"),
    ("host_bad_port", b"GET / HTTP/1.1\r\nHost: a:99999\r\n\r\n"),
    # --- Content-Length -------------------------------------------------
    ("cl_ok", post(b"Content-Length: 5", b"hello")),
    ("cl_plus", post(b"Content-Length: +5", b"hello")),
    ("cl_leading_zero", post(b"Content-Length: 05", b"hello")),
    ("cl_list_same", post(b"Content-Length: 5,5", b"hello")),
    ("cl_list_space", post(b"Content-Length: 5, 5", b"hello")),
    ("cl_space_inside", post(b"Content-Length: 5 5", b"hello")),
    ("cl_empty", post(b"Content-Length:", b"hello")),
    ("cl_negative", post(b"Content-Length: -1", b"hello")),
    ("cl_hex", post(b"Content-Length: 0x5", b"hello")),
    ("cl_overflow", post(b"Content-Length: 99999999999999999999", b"hello")),
    ("cl_trailing_ws", post(b"Content-Length: 5 ", b"hello")),
    ("cl_two_same", post(b"Content-Length: 5\r\nContent-Length: 5", b"hello")),
    ("cl_two_diff", post(b"Content-Length: 5\r\nContent-Length: 6", b"hello!")),
    ("cl_short_body_then_req", post(b"Content-Length: 2", b"hiGET /x HTTP/1.1\r\nHost: x\r\n\r\n")),
    ("get_with_cl_body", b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"),
    ("get_body_no_cl", b"GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /x HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("post_no_cl_no_te", b"POST / HTTP/1.1\r\nHost: x\r\n\r\nhello"),
    # --- Transfer-Encoding ----------------------------------------------
    ("te_chunked", te(b"chunked", CH)),
    ("te_chunked_trailing_ws", te(b"chunked ", CH)),
    ("te_Chunked", te(b"Chunked", CH)),
    ("te_chunked_chunked", te(b"chunked, chunked", CH)),
    ("te_gzip_chunked", te(b"gzip, chunked", CH)),
    ("te_chunked_gzip", te(b"chunked, gzip", CH)),
    ("te_identity", te(b"identity", b"hello")),
    ("te_xchunked", te(b"xchunked", CH)),
    ("te_chunked_vt", te(b"chunked\x0b", CH)),
    ("te_comma_chunked", te(b",chunked", CH)),
    ("te_two_lines", b"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n" + CH),
    ("te_and_cl", b"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n" + CH),
    ("te_http10", te(b"chunked", CH, b"HTTP/1.0")),
    ("te_http10_keepalive", b"POST / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\nTransfer-Encoding: chunked\r\n\r\n" + CH + b"GET /second HTTP/1.0\r\nHost: x\r\n\r\n"),
    ("te_on_get", b"GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" + CH),
    ("te_empty", te(b"", b"hello")),
    # --- chunked bodies -------------------------------------------------
    ("chunk_upper_hex", te(b"chunked", b"A\r\n0123456789\r\n0\r\n\r\n")),
    ("chunk_leading_zeros", te(b"chunked", b"0005\r\nhello\r\n0\r\n\r\n")),
    ("chunk_0x", te(b"chunked", b"0x5\r\nhello\r\n0\r\n\r\n")),
    ("chunk_size_trailing_space", te(b"chunked", b"5 \r\nhello\r\n0\r\n\r\n")),
    ("chunk_size_leading_space", te(b"chunked", b" 5\r\nhello\r\n0\r\n\r\n")),
    ("chunk_negative", te(b"chunked", b"-5\r\nhello\r\n0\r\n\r\n")),
    ("chunk_overflow", te(b"chunked", b"ffffffffffffffffff\r\nhello\r\n0\r\n\r\n")),
    ("chunk_ext", te(b"chunked", b"5;a=b\r\nhello\r\n0\r\n\r\n")),
    ("chunk_ext_quoted", te(b"chunked", b'5;a="b c"\r\nhello\r\n0\r\n\r\n')),
    ("chunk_ext_empty", te(b"chunked", b"5;\r\nhello\r\n0\r\n\r\n")),
    ("chunk_ext_bare_lf", te(b"chunked", b"5;a\nb\r\nhello\r\n0\r\n\r\n")),
    ("chunk_ext_bare_cr", te(b"chunked", b"5;a\rb\r\nhello\r\n0\r\n\r\n")),
    ("chunk_size_bare_lf", te(b"chunked", b"5\nhello\r\n0\r\n\r\n")),
    ("chunk_data_no_crlf", te(b"chunked", b"5\r\nhello0\r\n\r\n")),
    ("chunk_data_lf", te(b"chunked", b"5\r\nhello\n0\r\n\r\n")),
    ("chunk_data_too_long", te(b"chunked", b"3\r\nhello\r\n0\r\n\r\n")),
    ("last_chunk_lf", te(b"chunked", b"5\r\nhello\r\n0\r\n\n")),
    ("last_chunk_lf_smuggle", te(b"chunked", b"0\r\n\nGET /admin HTTP/1.1\r\nHost: x\r\n\r\n")),
    ("trailer_ok", te(b"chunked", b"0\r\nX: y\r\n\r\n")),
    ("trailer_bare_lf", te(b"chunked", b"0\r\nX: y\n\r\n")),
    ("trailer_cr_run", te(b"chunked", b"0\r\n\r\r\n")),
    ("trailer_no_colon", te(b"chunked", b"0\r\nXY\r\n\r\n")),
    ("trailer_then_request", te(b"chunked", b"0\r\nX: y\r\n\r\nGET /next HTTP/1.1\r\nHost: x\r\n\r\n")),
    ("last_chunk_ext", te(b"chunked", b"0;a=b\r\n\r\n")),
    # --- Expect, Connection, pipelining ---------------------------------
    ("expect_100", b"POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello"),
    ("expect_100_upper", b"POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-CONTINUE\r\nContent-Length: 5\r\n\r\nhello"),
    ("expect_unknown", b"POST / HTTP/1.1\r\nHost: x\r\nExpect: foo\r\nContent-Length: 5\r\n\r\nhello"),
    ("expect_http10", b"POST / HTTP/1.0\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello"),
    ("conn_close_list", b"GET /a HTTP/1.1\r\nHost: x\r\nConnection: close, TE\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("conn_close_upper", b"GET /a HTTP/1.1\r\nHost: x\r\nConnection: CLOSE\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("conn_close_then_req", b"GET /a HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"),
    ("http10_then_req", b"GET /a HTTP/1.0\r\nHost: x\r\n\r\nGET /b HTTP/1.0\r\nHost: x\r\n\r\n"),
    ("http10_keepalive_then_req", b"GET /a HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\nGET /b HTTP/1.0\r\nHost: x\r\n\r\n"),
    ("pipeline_two", G + G),
    ("pipeline_post_get", post(b"Content-Length: 5", b"hello") + G),
    ("pipeline_chunked_get", te(b"chunked", CH) + G),
]
