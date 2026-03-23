from .common_response import *
from .request import *
from .response import *


trait Encodable:
    def encode(var self) -> Bytes:
        ...


@always_inline
def encode[T: Encodable](var data: T) -> Bytes:
    return data^.encode()
