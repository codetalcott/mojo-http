"""Application state, and the pure functions that shape it into contexts.

This is the "functional core" half of the repo's stated design principle.
Nothing here takes a request or returns a response, so every one of these
is testable by calling it — which is the property Django's
`TemplateResponse` is reaching for when it keeps the context around instead
of rendering eagerly.

The store is in-memory parallel lists, the convention this repo uses
elsewhere, and deliberately not a database: the example is about the shape
of a view. Notes do not survive a restart, and under `M0_WORKERS>1` each
worker would get its own store — run one process.
"""

from views_pattern.templates import IndexPage, NotePage


struct NoteStore(Movable):
    """One per serving thread, handed to every view as its third argument."""

    var ids: List[Int]
    var titles: List[String]
    var bodies: List[String]
    var next_id: Int
    var api_key: String
    """Empty means the writing views are open. `M0_API_KEY` sets it."""

    def __init__(out self, var api_key: String):
        self.ids = List[Int]()
        self.titles = List[String]()
        self.bodies = List[String]()
        self.next_id = 1
        self.api_key = api_key^

    # --- pure reads: state -> context ---------------------------------------

    def index_page(self) -> IndexPage:
        """The list page's context."""
        var ids = List[Int]()
        var titles = List[String]()
        for i in range(len(self.ids)):
            ids.append(self.ids[i])
            titles.append(self.titles[i])
        return IndexPage(ids^, titles^)

    def note_page(self, id: Int) -> Optional[NotePage]:
        """One note's context, or nothing if no note has that id.

        `Optional` rather than a raise, so the 404 in the view is an
        ordinary early return and not an exception crossing the handler
        boundary on a hot path.
        """
        var i = self._find(id)
        if i < 0:
            return None
        return NotePage(self.ids[i], self.titles[i], self.bodies[i])

    # --- writes -------------------------------------------------------------

    def add(mut self, var title: String, var body: String) -> Int:
        """Store a note and return its id. Ids are stable and never reused."""
        var id = self.next_id
        self.next_id += 1
        self.ids.append(id)
        self.titles.append(title^)
        self.bodies.append(body^)
        return id

    def remove(mut self, id: Int) -> Bool:
        """Whether a note with that id was there to delete."""
        var i = self._find(id)
        if i < 0:
            return False
        # Swap-pop all three lists in lockstep; order is not part of the API.
        var last = len(self.ids) - 1
        self.ids[i] = self.ids[last]
        self.titles[i] = self.titles[last]
        self.bodies[i] = self.bodies[last]
        _ = self.ids.pop()
        _ = self.titles.pop()
        _ = self.bodies.pop()
        return True

    def _find(self, id: Int) -> Int:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        return -1
