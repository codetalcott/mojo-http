"""What the image this app runs in says about itself, read once at startup.

`deploy/mojo/Dockerfile` measures its own runtime stage as the image's last
layer -- the unpacked bytes of the whole filesystem and of `/app`, and
whether an interpreter is anywhere in it, failing the build if one is --
and writes the result to the file `M0_IMAGE_FACTS` names. The page's footer
and `/about` say what that file says and nothing else, so the claims
"no Python in this image" and its size are the build's measurements, not
prose; `poe smoke-blobs-image` checks both again from outside the
container.

Outside an image the variable is unset and nothing is claimed. A file that
is named but unreadable or malformed is refused rather than skipped: the
server would otherwise start in an image whose page silently dropped the
claims the image was built to make.
"""

from std.os import getenv

from m0_core.json_parse import parse_json_bool, parse_json_int, parse_json_string

from m0_http import attr, el, text

comptime SOURCE_URL = "https://github.com/codetalcott/mojo-http/tree/main/apps/blobs"
"""Where the app's source is read, linked from the footer."""


struct ImageFacts(Copyable, Movable):
    """The facts file, verbatim, and the four fields the footer reads."""

    var json: String
    """The file as written, or empty outside an image."""
    var version: String
    var python: Bool
    var app_bytes: Int
    var image_bytes: Int

    def __init__(out self):
        """No image: nothing to claim."""
        self.json = String()
        self.version = String()
        self.python = True
        self.app_bytes = 0
        self.image_bytes = 0

    def __init__(out self, json: String) raises:
        """Parse a facts file; raise naming the first field that is wrong."""
        self.json = json
        var version = parse_json_string(json, "version")
        var python = parse_json_bool(json, "python")
        var app_bytes = parse_json_int(json, "app_bytes")
        var image_bytes = parse_json_int(json, "image_bytes")
        if not version or version.value().byte_length() == 0:
            raise Error("the image facts carry no version")
        if not python:
            raise Error("the image facts do not say whether Python is present")
        if not app_bytes or not image_bytes:
            raise Error("the image facts carry no sizes")
        if app_bytes.value() <= 0 or image_bytes.value() < app_bytes.value():
            raise Error("the image facts' sizes are not sizes")
        self.version = version.value()
        self.python = python.value()
        self.app_bytes = app_bytes.value()
        self.image_bytes = image_bytes.value()

    def present(self) -> Bool:
        """Whether this process runs from an image that described itself."""
        return self.json.byte_length() > 0


def read_image_facts() raises -> ImageFacts:
    """The facts `M0_IMAGE_FACTS` names, or none when it is unset."""
    var path = getenv("M0_IMAGE_FACTS", "")
    if path.byte_length() == 0:
        return ImageFacts()
    var body: String
    try:
        with open(path, "r") as f:
            body = f.read()
    except e:
        raise Error(String("M0_IMAGE_FACTS names ", path, ", which cannot be read: ", e))
    return ImageFacts(body)


def megabytes(n: Int) -> String:
    """`n` bytes as decimal megabytes to one place: `102.1 MB`."""
    var tenths = (n + 50_000) // 100_000
    return String(tenths // 10, ".", tenths % 10, " MB")


def render_footer(facts: ImageFacts) raises -> String:
    """The footer: what the image is, when there is one to describe.

    Every figure comes from `facts`. The Python clause appears only when
    the build measured none, which it must have for the build to finish.
    """
    if not facts.present():
        return String()
    var line = String("m0 ", facts.version, " · pure Mojo")
    if not facts.python:
        line += " · no Python in this image"
    line += String(
        " · ", megabytes(facts.image_bytes), " unpacked, ",
        megabytes(facts.app_bytes), " of it this app · ",
    )
    return el(
        "footer",
        attr("class", "foot"),
        text(line) + el("a", attr("href", SOURCE_URL), text("source")),
    )
