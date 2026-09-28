"""The entry point that fails: its settings raise at import."""


def _settings():
    raise RuntimeError("REDIS_URL is not set")


application = _settings()
