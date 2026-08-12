"""Encodable trait for HTTP message types.

Defined in its own module rather than in this package's `__init__.mojo` so that
`request.mojo` and `response.mojo` can import it explicitly. Importing it from
the package initializer would be circular, since that initializer star-imports
both of those modules.
"""

from lightbug_http.io.bytes import Bytes


trait Encodable:
    def encode(var self) -> Bytes:
        ...


@always_inline
def encode[T: Encodable](var data: T) -> Bytes:
    return data^.encode()
