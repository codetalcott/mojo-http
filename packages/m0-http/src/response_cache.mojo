"""Per-URL response cache with LRU eviction.

Stores the last response buffer, ETag, and JSON string for each URL path.
Uses parallel arrays (SoA) since List[List[UInt8]] requires SoA layout
in Mojo to avoid ImplicitlyCopyable issues.
"""


struct ResponseCache:
    """URL-keyed response cache with LRU eviction using parallel arrays."""
    var urls: List[String]
    var etags: List[String]
    var buffers: List[List[UInt8]]
    var json_strings: List[String]
    var last_access: List[Int]
    var access_counter: Int
    var max_entries: Int

    fn __init__(out self, max_entries: Int = 256):
        self.urls = List[String]()
        self.etags = List[String]()
        self.buffers = List[List[UInt8]]()
        self.json_strings = List[String]()
        self.last_access = List[Int]()
        self.access_counter = 0
        self.max_entries = max_entries

    fn find(mut self, url: String) -> Int:
        """Find cache entry index for URL. Returns -1 if not found.
        Updates LRU access counter on hit."""
        for i in range(len(self.urls)):
            if self.urls[i] == url:
                self.access_counter += 1
                self.last_access[i] = self.access_counter
                return i
        return -1

    fn get_etag(mut self, url: String) -> String:
        """Get cached ETag for URL. Returns empty string if not cached."""
        var idx = self.find(url)
        if idx == -1:
            return String("")
        return String(self.etags[idx])

    fn get_buffer(mut self, url: String) -> List[UInt8]:
        """Get cached buffer for URL. Returns empty list if not cached."""
        var idx = self.find(url)
        if idx == -1:
            return List[UInt8]()
        return self.buffers[idx].copy()

    fn get_json(mut self, url: String) -> String:
        """Get cached JSON string for URL. Returns empty string if not cached."""
        var idx = self.find(url)
        if idx == -1:
            return String("")
        return String(self.json_strings[idx])

    fn put(mut self, url: String, buffer: List[UInt8], etag: String, json: String = ""):
        """Store or update a cache entry."""
        var idx = self.find(url)
        if idx != -1:
            self.buffers[idx] = buffer.copy()
            self.etags[idx] = etag
            self.json_strings[idx] = json
            return

        if len(self.urls) >= self.max_entries:
            self._evict_lru()

        self.access_counter += 1
        self.urls.append(url)
        self.etags.append(etag)
        self.buffers.append(buffer.copy())
        self.json_strings.append(json)
        self.last_access.append(self.access_counter)

    fn invalidate(mut self, url: String):
        """Remove a cache entry by URL."""
        var idx = self._find_no_touch(url)
        if idx == -1:
            return
        self._remove_at(idx)

    fn invalidate_prefix(mut self, prefix: String):
        """Remove all cache entries whose URL starts with prefix."""
        var i = 0
        while i < len(self.urls):
            if self.urls[i].startswith(prefix):
                self._remove_at(i)
            else:
                i += 1

    fn size(self) -> Int:
        """Return the number of cached entries."""
        return len(self.urls)

    fn _find_no_touch(self, url: String) -> Int:
        for i in range(len(self.urls)):
            if self.urls[i] == url:
                return i
        return -1

    fn _remove_at(mut self, idx: Int):
        """Remove entry at index using swap-with-last."""
        var last = len(self.urls) - 1
        if idx != last:
            self.urls[idx] = self.urls[last]
            self.etags[idx] = self.etags[last]
            self.buffers[idx] = self.buffers.pop()
            self.json_strings[idx] = self.json_strings[last]
            self.last_access[idx] = self.last_access[last]
            _ = self.urls.pop()
            _ = self.etags.pop()
            _ = self.json_strings.pop()
            _ = self.last_access.pop()
        else:
            _ = self.urls.pop()
            _ = self.etags.pop()
            _ = self.buffers.pop()
            _ = self.json_strings.pop()
            _ = self.last_access.pop()

    fn _evict_lru(mut self):
        """Evict the least recently used entry."""
        if len(self.urls) == 0:
            return
        var min_idx = 0
        var min_access = self.last_access[0]
        for i in range(1, len(self.urls)):
            if self.last_access[i] < min_access:
                min_access = self.last_access[i]
                min_idx = i
        self._remove_at(min_idx)
