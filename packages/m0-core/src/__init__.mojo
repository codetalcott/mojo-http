"""
m0-core: Zero-dependency foundation for the M0 framework.

Provides hashing, Result[T], pipeline combinators, AOP combinators,
JSON escape utilities. C-ABI FFI exports live in ffi/ (outside src/, build target only).
"""

from .hashing import (
    fnv1a, fnv1a_step, format_hash, format_hash32, format_hash64,
    xxhash32, format_xxhash, fnv1a_batch, xxhash32_batch,
    wyhash64, wyhash64_string, hex_nibble,
    _fnv1a_ptr, _xxhash32_ptr, _read_u32_ptr,
)
from .result import Result, Ok, Err, map_result, flat_map_result
from .aop import identity, constant, fork, hook, atop, over, under
from .pipeline import compose, compose3, pipe_2, pipe_3, pipe_4, PipelineContext, pipe_ctx_2, pipe_ctx_3
from .json_escape import escape_json_string, simd_find_escape_char
from .json_parse import parse_json_field, parse_json_int, parse_json_number, parse_json_bool
