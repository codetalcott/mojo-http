"""
`m0-core`: Zero-dependency foundation for the M0 framework.

Provides wyhash64 (the ETag hash), SHA-256 and HMAC-SHA256 with a
constant-time compare, SIMD-accelerated JSON string escaping, HTML text
escaping, and lightweight JSON field parsing.
C-ABI FFI exports live in ffi_exports.mojo at the package root — outside
src/ because it is the `mojo build --emit shared-lib` entry point (see its
docstring); `poe build-ffi` emits the shared object.
"""

from .hashing import (
    format_hash64, wyhash64, wyhash64_string, hex_nibble, hex_digest,
)
from .sha256 import Sha256, sha256, sha256_hex, SHA256_DIGEST_SIZE, SHA256_BLOCK_SIZE
from .hmac import HmacSha256, hmac_sha256, constant_time_equal
from .json_escape import escape_json_string, escape_json_string_into, simd_find_escape_char
from .html_escape import escape_html, escape_html_into
from .json_parse import (
    has_json_field,
    parse_json_bool,
    parse_json_field,
    parse_json_int,
    parse_json_number,
    parse_json_string,
)
