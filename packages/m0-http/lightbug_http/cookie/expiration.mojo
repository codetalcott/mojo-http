"""Stub Expiration module — small_time dependency removed for this vendored build."""

from std.collections import Optional


@fieldwise_init
struct Expiration(Copyable):
    """Stub Expiration that only supports session cookies."""

    var variant: UInt8

    @staticmethod
    def session() -> Self:
        return Self(variant=0)

    @staticmethod
    def from_string(str: String) -> Optional[Expiration]:
        return None

    @staticmethod
    def invalidate() -> Self:
        return Self(variant=1)

    def is_session(self) -> Bool:
        return self.variant == 0

    def is_datetime(self) -> Bool:
        return False

    def http_date_timestamp(self) raises -> Optional[String]:
        return Optional[String](None)

    def copy(self) -> Self:
        return Self(variant=self.variant)

    def __eq__(self, other: Self) -> Bool:
        return self.variant == other.variant
