"""The tag functions of the component tier, one per HTML element.

Each is one line over `_element` or `_void_element` in `html.mojo`: the
name is the element's, capitalised (`Div`, `H1`, `Textarea`), children are
`Child` (a bare string is text, an `El` is markup, a `List[El]` is each in
turn) and attributes are keywords (`cls` for `class`, `_for` for `for`,
`hx_boost` for `hx-boost`; a `Bool` is the attribute's presence, an
`Int` its decimal). A void element takes keywords only, so a child
handed to `Input` or `Img` is a compile error. A swap attribute typed as
a keyword is refused at render: a swapping element is
`Fragment.element(tag, verb, url, ...)`.

Imported by name — `from m0_http.tags import Div, Form, Input, Li` — and
not from `m0_http`'s root, where `Form` is the parsed form and `Html` the
builder. There is no `Html` tag for the same reason; the document element
is the page shell's, or `element("html", ...)`.

Written by hand once from the HTML living standard's element list, without
the obsolete elements and without `html`; a tag it lacks is
`element(tag, ...)`. Bodies are elaborated lazily, so the size of this
list costs an application that uses seven of them nothing measurable
(0.4 s on a warm build of two hundred call sites, 2026-10-24).
"""

from .html import AttrValue, Child, El, _element, _void_element


def A(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("a", children, attrs)

def Abbr(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("abbr", children, attrs)

def Address(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("address", children, attrs)

def Article(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("article", children, attrs)

def Aside(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("aside", children, attrs)

def Audio(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("audio", children, attrs)

def B(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("b", children, attrs)

def Bdi(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("bdi", children, attrs)

def Bdo(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("bdo", children, attrs)

def Blockquote(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("blockquote", children, attrs)

def Body(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("body", children, attrs)

def Button(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("button", children, attrs)

def Canvas(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("canvas", children, attrs)

def Caption(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("caption", children, attrs)

def Cite(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("cite", children, attrs)

def Code(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("code", children, attrs)

def Colgroup(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("colgroup", children, attrs)

def Data(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("data", children, attrs)

def Datalist(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("datalist", children, attrs)

def Dd(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("dd", children, attrs)

def Del(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("del", children, attrs)

def Details(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("details", children, attrs)

def Dfn(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("dfn", children, attrs)

def Dialog(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("dialog", children, attrs)

def Div(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("div", children, attrs)

def Dl(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("dl", children, attrs)

def Dt(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("dt", children, attrs)

def Em(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("em", children, attrs)

def Fieldset(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("fieldset", children, attrs)

def Figcaption(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("figcaption", children, attrs)

def Figure(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("figure", children, attrs)

def Footer(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("footer", children, attrs)

def Form(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("form", children, attrs)

def H1(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("h1", children, attrs)

def H2(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("h2", children, attrs)

def H3(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("h3", children, attrs)

def H4(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("h4", children, attrs)

def H5(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("h5", children, attrs)

def H6(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("h6", children, attrs)

def Head(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("head", children, attrs)

def Header(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("header", children, attrs)

def Hgroup(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("hgroup", children, attrs)

def I(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("i", children, attrs)

def Iframe(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("iframe", children, attrs)

def Ins(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("ins", children, attrs)

def Kbd(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("kbd", children, attrs)

def Label(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("label", children, attrs)

def Legend(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("legend", children, attrs)

def Li(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("li", children, attrs)

def Main(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("main", children, attrs)

def Map(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("map", children, attrs)

def Mark(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("mark", children, attrs)

def Menu(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("menu", children, attrs)

def Meter(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("meter", children, attrs)

def Nav(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("nav", children, attrs)

def Noscript(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("noscript", children, attrs)

def Object(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("object", children, attrs)

def Ol(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("ol", children, attrs)

def Optgroup(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("optgroup", children, attrs)

def Option(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("option", children, attrs)

def Output(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("output", children, attrs)

def P(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("p", children, attrs)

def Picture(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("picture", children, attrs)

def Pre(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("pre", children, attrs)

def Progress(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("progress", children, attrs)

def Q(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("q", children, attrs)

def Rp(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("rp", children, attrs)

def Rt(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("rt", children, attrs)

def Ruby(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("ruby", children, attrs)

def S(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("s", children, attrs)

def Samp(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("samp", children, attrs)

def Script(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("script", children, attrs)

def Search(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("search", children, attrs)

def Section(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("section", children, attrs)

def Select(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("select", children, attrs)

def Slot(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("slot", children, attrs)

def Small(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("small", children, attrs)

def Span(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("span", children, attrs)

def Strong(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("strong", children, attrs)

def Style(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("style", children, attrs)

def Sub(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("sub", children, attrs)

def Summary(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("summary", children, attrs)

def Sup(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("sup", children, attrs)

def Table(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("table", children, attrs)

def Tbody(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("tbody", children, attrs)

def Td(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("td", children, attrs)

def Template(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("template", children, attrs)

def Textarea(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("textarea", children, attrs)

def Tfoot(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("tfoot", children, attrs)

def Th(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("th", children, attrs)

def Thead(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("thead", children, attrs)

def Time(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("time", children, attrs)

def Title(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("title", children, attrs)

def Tr(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("tr", children, attrs)

def U(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("u", children, attrs)

def Ul(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("ul", children, attrs)

def Var(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("var", children, attrs)

def Video(*children: Child, var **attrs: AttrValue) raises -> El:
    return _element("video", children, attrs)


# --- void elements: keywords only, no children, no closing tag ---------------

def Area(var **attrs: AttrValue) raises -> El:
    return _void_element("area", attrs)

def Base(var **attrs: AttrValue) raises -> El:
    return _void_element("base", attrs)

def Br(var **attrs: AttrValue) raises -> El:
    return _void_element("br", attrs)

def Col(var **attrs: AttrValue) raises -> El:
    return _void_element("col", attrs)

def Embed(var **attrs: AttrValue) raises -> El:
    return _void_element("embed", attrs)

def Hr(var **attrs: AttrValue) raises -> El:
    return _void_element("hr", attrs)

def Img(var **attrs: AttrValue) raises -> El:
    return _void_element("img", attrs)

def Input(var **attrs: AttrValue) raises -> El:
    return _void_element("input", attrs)

def Link(var **attrs: AttrValue) raises -> El:
    return _void_element("link", attrs)

def Meta(var **attrs: AttrValue) raises -> El:
    return _void_element("meta", attrs)

def Source(var **attrs: AttrValue) raises -> El:
    return _void_element("source", attrs)

def Track(var **attrs: AttrValue) raises -> El:
    return _void_element("track", attrs)

def Wbr(var **attrs: AttrValue) raises -> El:
    return _void_element("wbr", attrs)
