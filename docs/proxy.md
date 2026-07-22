# Enterprise proxy support

Every network-touching part of this repo — `scripts/fetch-artifacts.sh` (host-side
downloads), the `Containerfile`'s `microdnf install` steps, and
`Containerfile.deps`'s `cpanm`/`carton install` (CPAN downloads) — honors the
standard `http_proxy` / `https_proxy` / `no_proxy` environment variables. No proxy
configured means no change in behavior.

## The short version

```bash
export https_proxy=http://proxy.corp.example:8080
export no_proxy=localhost,127.0.0.1,.internal.corp.example
make fetch-artifacts
make bundle
make all
```

Or as a one-off override, same as `UBI_IMAGE`/`IMAGE_NAME`:

```bash
make bundle https_proxy=http://proxy.corp.example:8080
```

Uppercase `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` also work — every entry-point
script folds them in as a fallback if the lowercase form isn't set. You don't need
to know which casing a given tool actually reads; use either.

## Why this needed more than "just read HTTP_PROXY"

Every URL this repo fetches is `https://`, and https-proxying works differently
from plain http-proxying (it needs an HTTP `CONNECT` tunnel, not just a routed
request) — so "does this tool support a proxy" and "does it support proxying
*https*" are two different questions. Three tools are involved, and each was
checked directly rather than assumed:

- **`curl`** (`fetch-artifacts.sh`, host-side): reads lowercase `http_proxy`/
  `https_proxy`/`no_proxy`. It deliberately does *not* read uppercase
  `HTTP_PROXY` for plain `http://` requests — a deliberate security choice after
  the 2016 "httpoxy" CVE, where a client-supplied `Proxy:` header could get
  turned into `HTTP_PROXY` by some CGI setups. It does read `HTTPS_PROXY`. Since
  everything here is `https://`, this asymmetry never actually bites.
- **`microdnf`/`dnf`** (the `perl-src`/`base` stages' `RUN microdnf install`):
  backed by `librepo` (libcurl-based), which honors the same env vars. Combined
  with `podman build`'s own `--http-proxy` (default `true`, passes host proxy
  env vars into the build), this mostly already worked — but only implicitly,
  and only for whichever podman/buildah version's default happens to still be
  `true`. `Containerfile`/`Containerfile.deps` now declare `ARG`/`ENV`
  `http_proxy`/`https_proxy`/`no_proxy` explicitly (same pattern as `UBI_IMAGE`),
  so it doesn't depend on that implicit behavior.
- **`cpanm`/`Carton`** (inside `Containerfile.deps`, downloading every CPAN
  dependency during `make bundle`/`make update`): this is the one worth
  understanding, because the `dev-tools` stage installs neither `curl` nor
  `wget` — Carton's only HTTP option there is Perl's own core `HTTP::Tiny`.
  Core Perl 5.28.1 (this repo's default `PERL_VERSION`) bundles `HTTP::Tiny`
  0.070. Rather than assume, its actual source was inspected directly:
  `_open_handle`/`_proxy_connect` in 0.070 already implement full CONNECT-tunnel
  proxying for `https://` through an `http://` proxy, reading
  `$ENV{http_proxy}`/`$ENV{https_proxy}`/`$ENV{all_proxy}`/`$ENV{no_proxy}`
  (lowercase only — no uppercase fallback inside HTTP::Tiny itself, which is
  why the fold-in happens in the shell scripts instead). This was also
  confirmed empirically: a real CONNECT request through a local test proxy
  succeeded with both HTTP::Tiny 0.070 (installed standalone, matching what
  5.28.1 bundles) and 0.086 (bundled with Perl 5.38.2) — see the PR/commit this
  landed in for the actual proxy access-log evidence. Because core `HTTP::Tiny`
  only ever moves forward across Perl releases, this holds for any
  `PERL_VERSION` this repo is bumped to (see
  [`architecture.md#changing-perl-version`](architecture.md#changing-perl-version)).

**Net effect**: every tool already speaks the same lowercase convention. The
actual gaps closed here were (a) making the Containerfile's proxy passthrough
explicit instead of relying on an unstated builder default, and (b) normalizing
an uppercase-only corporate environment down to what the tools underneath
actually read.

## This is a different concern from `certs/`

The existing `certs/` mechanism (drop a corporate CA cert in, gitignored) makes
TLS *validation succeed* once a TLS-inspecting proxy is in the traffic path — it
does nothing to make traffic *reach* a proxy in the first place. A corporate
TLS-inspecting proxy setup usually needs **both**: `http_proxy`/`https_proxy` to
route there, and `certs/` so the connection to it doesn't fail cert validation.
Neither substitutes for the other.

## `NO_PROXY`

Standard suffix-match semantics (the same convention `curl` and `HTTP::Tiny` both
use): each entry matches any hostname ending with it. Useful if there's an
internal CPAN mirror, internal registry, or internal artifact store that should
bypass the proxy:

```bash
export no_proxy=localhost,127.0.0.1,.internal.corp.example
```

## Troubleshooting

- **`make fetch-artifacts` hangs or times out**: confirm `https_proxy` is set
  and reachable (`curl -v https://fastapi.metacpan.org` should show `CONNECT` in
  the trace if a proxy is active).
- **`microdnf install` fails inside the build but `fetch-artifacts.sh` worked
  fine on the host**: the proxy env vars need to reach the *build*, not just
  your shell — confirm you're using `make`/`scripts/deps.sh`/`scripts/build-image.sh`
  (which pass them as `--build-arg`), not a bare `podman build` that drops them.
- **`carton install` fails inside `Containerfile.deps` specifically**: this is
  the `HTTP::Tiny`-only path described above — double-check `no_proxy` doesn't
  accidentally match the CPAN mirror's hostname, and that the proxy itself
  supports the `CONNECT` method (some restrictive proxies only allow it to a
  small allowlist of ports/hosts).
