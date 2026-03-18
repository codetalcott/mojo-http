"""Stub Expiration module — small_time dependency removed for this vendored build."""

from std.collections import Optional


@fieldwise_init
struct Expiration(Copyable):
    """Stub Expiration that only supports session cookies."""

    var variant: UInt8

    @staticmethod
    fn session() -> Self:
        return Self(variant=0)

    @staticmethod
    fn from_string(str: String) -> Optional[Expiration]:
        return None

    @staticmethod
    fn invalidate() -> Self:
        return Self(variant=1)

    fn is_session(self) -> Bool:
        return self.variant == 0

    fn is_datetime(self) -> Bool:
        return False

    fn http_date_timestamp(self) raises -> Optional[String]:
        return Optional[String](None)

    fn copy(self) -> Self:
        return Self(variant=self.variant)

    fn __eq__(self, other: Self) -> Bool:
        return self.variant == other.variant
