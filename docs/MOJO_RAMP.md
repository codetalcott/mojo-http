# From m0serve to Mojo

A Django or Flask application served by m0serve can move one route at a
time into compiled Mojo, in the same process and behind the same port. The
unit that moves is a views module. The same module later builds into a
binary with no Python in it.

## One module, two hosts

`apps/ramp/views.mojo` in the repository is a [views table](MOJO_VIEWS.md),
its views and its state, and nothing that knows which server it is on. It
builds two ways.

**Inside m0serve, as a mount.**

```bash
m0serve --mount /=project.wsgi:application --mount /x=mojo
```

Requests under `/x` go to the compiled table on handler threads that never
take the GIL; everything else goes to the Python application. Each mount
has its own execution mode, so a slow Python view does not queue the Mojo
routes behind it. The Python application keeps authentication and every
page nobody has moved.

**On the Mojo host, alone.** `serve[ViewsApp[Ramp]](config)` is the whole
`main` ([the host](MOJO_HOST.md)). No interpreter is in the process or the
image.

CI builds both from the one file on every pull request and sends each the
same requests under the prefix: the index, a route answered on the event
loop, a compute route, a 404 inside the prefix, a 405 with its `Allow`, an
`OPTIONS`. The answers are byte-identical apart from `Date`, and a link
rendered by one host resolves on the other (N20 in
[Capabilities](SPEC.md)).

## What makes a module portable

- **The prefix is a value.** The table is built as `Views[S](Mount("/x"))`
  and every link goes through that `Mount`'s `url_for`. A request under a
  mount arrives with its whole path, so a link rendered as `/now` would
  land on the Python application.
- **The state is built from the prefix alone**, so both adapters call one
  function.
- **No body says where it ran.** A thread index means a handler thread on
  one host and the loop on the other.
- **A route that must not queue is `add_loop`**, on both hosts.

Each adapter is about a page: `apps/ramp/mount/m0serve_mount.mojo` for the
mount, `apps/ramp/server.mojo` for the host.

## What each side needs

A host binary is built by `m0`, from a project `m0 new` wrote:
[Quickstart (Mojo)](../packaging/m0/QUICKSTART.md).

A mount is compiled into m0serve itself. The `m0serve` wheel on PyPI
carries a demonstration mount, not yours, so serving your own module under
m0serve means building m0serve from a checkout of the repository, with
`M0SERVE_MOUNT_DIR` naming the directory that holds your
`m0serve_mount.mojo` and `M0SERVE_INCLUDE` your module's root. `m0` does
not do this build.

## Holds work from a mount

Under `--realtime`, a Mojo view on a mount takes a Server-Sent Events hold
with the same two response headers a Django view uses, `M0-Hold` and
`M0-Channel`, and `m0pub.publish()` from Python reaches it. A streaming
response that is not a hold is refused from a mount.

`--mount /rt=hold` is a built-in mount for the opposite split: the Python
view signs a short-lived grant into the stream's URL, and the mount verifies
it and holds the connection without calling Python again
([After the quickstart](QUICKSTART_NEXT.md)).

The measurements behind the split, including what a full handler pool
costs a loop route on each host, are in
[the ramp test](notes/the-ramp-test.md).
