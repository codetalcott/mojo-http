from lightbug_http.cookie.duration import Duration
from lightbug_http.cookie.expiration import Expiration
from lightbug_http.cookie.same_site import SameSite
from lightbug_http.header import Header, HeaderKey
from std.utils import Variant


struct Cookie(Copyable):
    comptime EXPIRES = "Expires"
    comptime MAX_AGE = "Max-Age"
    comptime DOMAIN = "Domain"
    comptime PATH = "Path"
    comptime SECURE = "Secure"
    comptime HTTP_ONLY = "HttpOnly"
    comptime SAME_SITE = "SameSite"
    comptime PARTITIONED = "Partitioned"

    comptime SEPARATOR = "; "
    comptime EQUAL = "="

    var name: String
    var value: String
    var expires: Expiration
    var secure: Bool
    var http_only: Bool
    var partitioned: Bool
    var same_site: Optional[SameSite]
    var domain: Optional[String]
    var path: Optional[String]
    var max_age: Optional[Duration]

    def __init__(
        out self,
        name: String,
        value: String,
        expires: Expiration = Expiration.session(),
        max_age: Optional[Duration] = Optional[Duration](None),
        domain: Optional[String] = Optional[String](None),
        path: Optional[String] = Optional[String](None),
        same_site: Optional[SameSite] = Optional[SameSite](None),
        secure: Bool = False,
        http_only: Bool = False,
        partitioned: Bool = False,
    ):
        self.name = name
        self.value = value
        self.expires = expires.copy()
        self.max_age = max_age
        self.domain = domain
        self.path = path
        self.secure = secure
        self.http_only = http_only
        self.same_site = same_site
        self.partitioned = partitioned

    def __str__(self) -> String:
        return String("Name: ", self.name, " Value: ", self.value)

    def to_header(self) raises -> Header:
        return Header(HeaderKey.SET_COOKIE, self.build_header_value())

    def build_header_value(self) -> String:
        var header_value = String(self.name, Cookie.EQUAL, self.value)
        if self.expires.is_datetime():
            var v: Optional[String]
            try:
                v = self.expires.http_date_timestamp()
            except:
                v = None
                # TODO: This should be a hardfail however Writeable trait write_to method does not raise
                # the call flow needs to be refactored
                pass

            if v:
                header_value.write(Cookie.SEPARATOR, Cookie.EXPIRES, Cookie.EQUAL, v.value())
        if self.max_age:
            header_value.write(
                Cookie.SEPARATOR,
                Cookie.MAX_AGE,
                Cookie.EQUAL,
                String(self.max_age.value().total_seconds),
            )
        if self.domain:
            header_value.write(
                Cookie.SEPARATOR,
                Cookie.DOMAIN,
                Cookie.EQUAL,
                self.domain.value(),
            )
        if self.path:
            header_value.write(Cookie.SEPARATOR, Cookie.PATH, Cookie.EQUAL, self.path.value())
        if self.secure:
            header_value.write(Cookie.SEPARATOR, Cookie.SECURE)
        if self.http_only:
            header_value.write(Cookie.SEPARATOR, Cookie.HTTP_ONLY)
        if self.same_site:
            header_value.write(
                Cookie.SEPARATOR,
                Cookie.SAME_SITE,
                Cookie.EQUAL,
                String(self.same_site.value()),
            )
        if self.partitioned:
            header_value.write(Cookie.SEPARATOR, Cookie.PARTITIONED)
        return header_value
