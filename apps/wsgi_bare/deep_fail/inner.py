"""The frame the traceback must name."""


def load():
    raise RuntimeError("DATABASE_URL is not set")


settings = load()
