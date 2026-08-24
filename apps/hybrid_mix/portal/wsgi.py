"""The second mounted application: a different framework, same process.

Flask rather than a second Django project on purpose. Two Django projects
would share `django.conf.settings`, and the first one imported would win --
which would make the example quietly a lie about isolation. Two frameworks
cannot accidentally share anything, so this proves what it claims: each
mount gets its own bridge, its own shim namespace, and its own prefix.

`url_for` is the assertion that matters here, for the same reason
`reverse()` is on the Django side: Flask builds it from SCRIPT_NAME.
"""

import json

from flask import Flask, Response, request, url_for

app = Flask(__name__)


@app.get("/")
def root():
    return Response("hello from flask on mojo-http", mimetype="text/plain")


@app.get("/where")
def where():
    return Response(
        json.dumps(
            {
                "script_name": request.environ.get("SCRIPT_NAME", ""),
                "path_info": request.environ.get("PATH_INFO", ""),
                "request_path": request.path,
                "url_for_where": url_for("where"),
                "base_url": request.base_url,
            }
        ),
        mimetype="application/json",
    )
