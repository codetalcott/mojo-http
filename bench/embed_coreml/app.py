"""bench/embed_coreml/app.py — MiniLM-L6-v2 embeddings as a WSGI service.

POST /embed  {"texts": ["...", ...]}  ->  {"embeddings": [[384 floats], ...],
                                           "backend": "coreml", "shape": [n, seq],
                                           "pid": <serving process>}
GET  /health                          ->  {"ok": true}

The engine is `@qkstat/embed`'s Core ML backend (mojo-addon-examples,
`packages/embed/coreml_backend.py`), found through QKSTAT_EMBED_DIR
(default: the sibling checkout); `npm run convert:coreml` there produces the
models. One app object, run under two servers for the comparison in
docs/notes/coreml-embeddings.md:

    m0serve --app-dir bench/embed_coreml app:application --workers 1 --blocking-threads 2
    uvicorn --app-dir bench/embed_coreml --interface wsgi app:application --workers 2

`MLModel.predict` holds the GIL, so under m0serve it belongs on a handler
thread (`--blocking-threads`), never inline on the loop. **Not a forked
`--workers 2`:** Core ML cannot run in a forked child. The Objective-C
runtime refuses (`+[NSPlaceholderString initialize] may have been in
progress in another thread when fork() was called`), and with that check
disabled the model load dies in CoreServices' libdispatch ("crashed on
child side of fork pre-exec") — CLAUDE.md's rule "after fork() without
exec, platform runtimes are off limits", measured 2026-09-04. Two
independent `m0serve --workers 1` on one port (bench_serve.py's
`--instances`) do not share the load on macOS either: SO_REUSEPORT hands
every connection to one listener. uvicorn's workers are spawned and
unaffected. The `pid` in each response is how the spread is measured.

Backend: QKSTAT_EMBED_BACKEND=coreml|max|auto, resolved by embed.py.
Tokenizer: HF `tokenizers`, loaded from the tokenizer.json coreml_convert.py
puts beside the models (the same WordPiece vocabulary tokenize.js uses).
From a FILE, never `from_pretrained`: that resolves proxies through macOS
_scproxy, and a prefork worker dies there with SIGKILL (CLAUDE.md, "After
fork() without exec"). Without the file it falls back to the hub, which is
fine under uvicorn's spawned workers and fatal under forked ones.
"""

from __future__ import annotations

import json
import os
import sys
import threading

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
EMBED_DIR = os.environ.get("QKSTAT_EMBED_DIR") or os.path.normpath(
    os.path.join(_HERE, "..", "..", "..", "mojo-addon-examples", "packages", "embed")
)
sys.path.insert(0, EMBED_DIR)  # embed.py, coreml_backend.py

MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
MAX_SEQ = 128
MAX_TEXTS = 256
_lock = threading.Lock()
_state: dict = {}


def _engine():
    if "engine" not in _state:
        with _lock:
            if "engine" not in _state:
                from tokenizers import Tokenizer

                import embed

                import coreml_backend

                tok_path = os.path.join(coreml_backend.cache_dir_from_env(), "tokenizer.json")
                tok = Tokenizer.from_file(tok_path) if os.path.isfile(tok_path) else Tokenizer.from_pretrained(MODEL_ID)
                tok.enable_truncation(MAX_SEQ)
                tok.enable_padding(pad_id=0, pad_token="[PAD]")
                engine = embed.get_engine(device=os.environ.get("QKSTAT_EMBED_DEVICE", "cpu"))
                if hasattr(engine, "warmup"):
                    engine.warmup()  # every bucket loaded before the first request
                _state["tok"] = tok
                _state["engine"] = engine
                _state["backend"] = embed.backend_name()
    return _state["engine"], _state["tok"], _state["backend"]


def embed_texts(texts: list[str]) -> tuple[np.ndarray, tuple[int, int]]:
    engine, tok, _ = _engine()
    encs = tok.encode_batch(texts)
    ids = np.array([e.ids for e in encs], dtype=np.int32)
    mask = np.array([e.attention_mask for e in encs], dtype=np.int32)
    return engine.embed_batch_l2(ids, mask), ids.shape


def _json(start_response, status: str, body: dict):
    data = json.dumps(body, separators=(",", ":")).encode()
    start_response(status, [("Content-Type", "application/json"), ("Content-Length", str(len(data)))])
    return [data]


def application(environ, start_response):
    path = environ.get("PATH_INFO", "/")
    if path == "/health":
        return _json(start_response, "200 OK", {"ok": True})
    if path != "/embed" or environ.get("REQUEST_METHOD") != "POST":
        return _json(start_response, "404 Not Found", {"error": "POST /embed"})
    try:
        n = int(environ.get("CONTENT_LENGTH") or 0)
        payload = json.loads(environ["wsgi.input"].read(n) or b"{}")
        texts = payload.get("texts")
        if not isinstance(texts, list) or not texts or not all(isinstance(t, str) for t in texts):
            return _json(start_response, "400 Bad Request", {"error": "texts: non-empty list of strings"})
        if len(texts) > MAX_TEXTS:
            return _json(start_response, "413 Payload Too Large", {"error": f"at most {MAX_TEXTS} texts"})
    except (ValueError, KeyError) as e:
        return _json(start_response, "400 Bad Request", {"error": str(e)})
    emb, shape = embed_texts(texts)
    return _json(
        start_response,
        "200 OK",
        {"embeddings": emb.round(6).tolist(), "backend": _state["backend"], "shape": list(shape), "pid": os.getpid()},
    )
