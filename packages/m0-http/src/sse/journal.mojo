"""Append-only event journal for SSE reconnect replay.

Stores patches and snapshots per URL, keyed by auto-incrementing event IDs.
Supports since(url, lastEventId) for reconnect — returns single patch
or snapshot fallback when multiple events have accumulated.

Uses SoA parallel arrays to avoid ImplicitlyCopyable issues.
"""


struct JournalResult:
    """Result from since() — type + data + etag + event_id."""

    var type: String          # "patch", "snapshot", or "none"
    var data: List[UInt8]     # patch or snapshot bytes
    var etag: String
    var base_etag: String
    var event_id: Int

    fn __init__(out self, type: String, data: List[UInt8], etag: String, base_etag: String, event_id: Int):
        self.type = type
        self.data = data.copy()
        self.etag = etag
        self.base_etag = base_etag
        self.event_id = event_id


struct PatchJournal:
    """Per-URL event log for SSE reconnect support."""

    var urls: List[String]
    var event_ids: List[Int]
    var base_etags: List[String]
    var new_etags: List[String]
    var patches: List[List[UInt8]]
    var snapshots: List[List[UInt8]]
    var next_id: Int
    var max_entries: Int

    fn __init__(out self, max_entries: Int = 100):
        self.urls = List[String]()
        self.event_ids = List[Int]()
        self.base_etags = List[String]()
        self.new_etags = List[String]()
        self.patches = List[List[UInt8]]()
        self.snapshots = List[List[UInt8]]()
        self.next_id = 1
        self.max_entries = max_entries

    fn append(
        mut self,
        url: String,
        base_etag: String,
        new_etag: String,
        patch: List[UInt8],
        snapshot: List[UInt8],
    ) -> Int:
        """Append a patch event. Returns the event ID."""
        var eid = self.next_id
        self.next_id += 1

        self.urls.append(url)
        self.event_ids.append(eid)
        self.base_etags.append(base_etag)
        self.new_etags.append(new_etag)
        self.patches.append(patch.copy())
        self.snapshots.append(snapshot.copy())

        if len(self.urls) > self.max_entries:
            self._compact_oldest()

        return eid

    fn since(self, url: String, last_event_id: Int) -> JournalResult:
        """Get events since last_event_id for a URL.

        Returns:
        - type="patch" when exactly 1 event since lastEventId
        - type="snapshot" when >1 events (merge fallback)
        - type="none" when no new events
        """
        var matching = List[Int]()
        for i in range(len(self.urls)):
            if self.urls[i] == url and self.event_ids[i] > last_event_id:
                matching.append(i)

        if len(matching) == 0:
            return JournalResult("none", List[UInt8](), String(""), String(""), 0)

        if len(matching) == 1:
            var idx = matching[0]
            return JournalResult(
                "patch",
                self.patches[idx].copy(),
                String(self.new_etags[idx]),
                String(self.base_etags[idx]),
                self.event_ids[idx],
            )

        var last_idx = matching[0]
        for mi in range(1, len(matching)):
            if self.event_ids[matching[mi]] > self.event_ids[last_idx]:
                last_idx = matching[mi]
        return JournalResult(
            "snapshot",
            self.snapshots[last_idx].copy(),
            String(self.new_etags[last_idx]),
            String(""),
            self.event_ids[last_idx],
        )

    fn latest_snapshot(self, url: String) -> JournalResult:
        """Get the latest snapshot for a URL."""
        var latest_idx = -1
        var latest_eid = -1
        for i in range(len(self.urls)):
            if self.urls[i] == url and self.event_ids[i] > latest_eid:
                latest_idx = i
                latest_eid = self.event_ids[i]

        if latest_idx == -1:
            return JournalResult("none", List[UInt8](), String(""), String(""), 0)

        return JournalResult(
            "snapshot",
            self.snapshots[latest_idx].copy(),
            String(self.new_etags[latest_idx]),
            String(""),
            self.event_ids[latest_idx],
        )

    fn latest_id(self) -> Int:
        """Return the most recent event ID, or 0 if empty."""
        return self.next_id - 1

    fn has_etag(self, url: String, etag: String) -> Int:
        """Check if journal has an entry for URL with matching etag.
        Returns the event_id if found, 0 if not."""
        for i in range(len(self.urls) - 1, -1, -1):
            if self.urls[i] == url and self.new_etags[i] == etag:
                return self.event_ids[i]
        return 0

    fn compact(mut self, url: String):
        """Remove all entries for a URL."""
        var i = 0
        while i < len(self.urls):
            if self.urls[i] == url:
                self._remove_at(i)
            else:
                i += 1

    fn _compact_oldest(mut self):
        """Remove oldest entries when over max_entries."""
        var to_remove = len(self.urls) // 4
        if to_remove < 1:
            to_remove = 1
        for _ in range(to_remove):
            if len(self.urls) == 0:
                break
            var min_idx = 0
            for i in range(1, len(self.event_ids)):
                if self.event_ids[i] < self.event_ids[min_idx]:
                    min_idx = i
            self._remove_at(min_idx)

    fn _remove_at(mut self, idx: Int):
        """Remove entry at index using swap-with-last."""
        var last = len(self.urls) - 1
        if idx != last:
            self.urls[idx] = self.urls[last]
            self.event_ids[idx] = self.event_ids[last]
            self.base_etags[idx] = self.base_etags[last]
            self.new_etags[idx] = self.new_etags[last]
            self.patches[idx] = self.patches[last].copy()
            self.snapshots[idx] = self.snapshots[last].copy()
        _ = self.urls.pop()
        _ = self.event_ids.pop()
        _ = self.base_etags.pop()
        _ = self.new_etags.pop()
        _ = self.patches.pop()
        _ = self.snapshots.pop()
