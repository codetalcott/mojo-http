You are starting in an empty directory on a developer's machine. Build a
small web application here, in Mojo, and prove it works.

The application: a page that shows a shared list of messages. Anyone can
add a message. When one browser tab adds a message, every other open tab
shows it without reloading. Write it with the `m0` tool and framework from
PyPI (`uvx m0 new` scaffolds a project; its documentation is at
https://m0serve.dev/mojo/ and is the only documentation you should need).
`uv` and a C compiler are installed; the Mojo toolchain is installed into
the project by `uv sync`.

The harness that checks your work will drive the application through this
contract, so meet it exactly:

- `run.sh PORT`, in this directory, starts the server in the foreground on
  `127.0.0.1:PORT`, building first if the binary is missing. It is run
  with `sh run.sh PORT`.
- `GET /` answers the page as HTML.
- `POST /messages` with a form field `text` adds a message; any 2xx or 3xx
  answer is fine.
- `GET /stream` is a Server-Sent Events stream (`text/event-stream`) on
  which every message added after the stream opened arrives, its text
  somewhere in the event's data, within a second or two of the POST. Two
  streams open at once both receive it.

Verify the contract yourself with curl before you finish: start the
server, open a stream, add a message from a second request, show the
message on the stream. Then stop every process you started and leave the
files in this directory. End with a short report: the commands that
proved it, and anything about the tool or framework that cost you time or
that its documentation should have said.
