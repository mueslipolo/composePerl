# Local routing demo (Traefik + compose)

Routes two real component services (`components/example`, `components/billing`)
by path prefix through Traefik, proving the "multiple components, one entry
point" model end to end. See [`../docs/multi-component.md`](../docs/multi-component.md)
for the architecture this validates.

## Prerequisites

- `common-dev`/`common-runtime` already built (`make common-dev common-runtime`,
  after `make bundle-common` — see the repo root README).
- `podman-compose` installed (`podman compose ...` delegates to it automatically
  if present).

## Running it

```bash
make compose-up
```

This bundles both components against the current `common` platform (same as
`make bundle-component COMPONENT=components/<name>`), stages each bundle next
to its `Containerfile` (the same manual step the CI job and local testing
already use — `bundles/` is gitignored, so the `Containerfile`'s `COPY bundle-latest.tar.gz` needs a real file alongside it, not just the symlink),
then runs `podman-compose up --build -d` from `compose/`.

Try it:

```bash
curl localhost:8080/example/
# example component OK: Capture::Tiny (common) + Test::Fatal (delta) both loaded

curl localhost:8080/billing/
# billing component OK: Try::Tiny (common) + Path::Tiny (delta) both loaded
```

Traefik's dashboard (routers/services, useful to see the two path-prefix
rules configured): http://localhost:8081/dashboard/

Tear down: `make compose-down`.

## Routing: static file provider, not label-based auto-discovery

`dynamic.yml` lists each component's router/service/middleware explicitly.
The alternative — Traefik watching the podman API and reading routing rules
straight from container labels, so a new component needs zero central config
— needs `podman.socket` enabled and mounted into the Traefik container. That's
untested in this environment and adds real setup complexity (rootless podman
socket permissions, API compatibility), so this first working version uses
the static file provider instead: reliable everywhere, at the cost of one
manual block in `dynamic.yml` per new component. Revisit label-based discovery
once podman-socket sharing is verified separately — the routing rules
themselves (`PathPrefix` + `stripPrefix`) don't change, only where Traefik
reads them from.

## Why Mojolicious, and why it's in `common/cpanfile`

Both components' `app.pl` are now real `Mojolicious::Lite` services
(`app->start`, run via `perl app.pl daemon -l http://*:3000` — see each
`Containerfile`'s `CMD`) instead of one-shot scripts. Mojolicious is
dependency-free, so adding it to the shared `common/cpanfile` — a genuinely
shared "every component gets the same HTTP framework" concern — didn't
change the resolution complexity of the demo BOM at all (still 3 total
distributions: `Try::Tiny`, `Capture::Tiny`, `Mojolicious`).
