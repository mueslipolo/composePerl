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

## Fetching artifacts from an internal Nexus instead of the public internet

`scripts/fetch-artifacts.sh` normally downloads the Perl source tarball,
`cpanm`, `cpm`, and the Oracle Instant Client zips directly from their public
upstreams (`cpan.org`, GitHub raw, `oracle.com`). In an environment without
direct internet egress, it can instead read them from an internal Nexus
raw-hosted repository:

```bash
export NEXUS_URL=https://nexus.example.org
make fetch-artifacts   # now reads from Nexus instead of the public internet
```

Someone still has to *populate* that Nexus repo in the first place — that's
`--mirror` (`make mirror-artifacts`): it always fetches from the real public
sources regardless of `NEXUS_URL` (mirroring is the one operation that must
reach the internet), verifies checksums exactly like a normal fetch, then
uploads each artifact into Nexus:

```bash
export NEXUS_URL=https://nexus.example.org
export NEXUS_USER=svc-mirror
export NEXUS_PASSWORD=...
make mirror-artifacts
```

**Assumption, to correct once real org access exists**: a single Nexus 3
raw-hosted repository, default name `raw-hosted` (override with
`NEXUS_REPOSITORY`), artifacts under a `composeperl/` subpath keyed by the
same filenames already used in `artifacts/`/`artifacts.sha256`. Fetching
(`GET`) is assumed anonymous-readable within the corp network — only
`--mirror`'s upload needs `NEXUS_USER`/`NEXUS_PASSWORD`. Nexus itself is
expected to be reachable per your `no_proxy` configuration above (an
environment concern, not something the script special-cases).

## Authenticating against a Docker/OCI registry (Nexus or otherwise)

Separate from the raw-hosted artifact repo above — pulling `UBI_IMAGE`
through an authenticated registry, or `make publish-platform` pushing
`common-dev`/`common-runtime`, both need `podman` to be logged in first:

```bash
make registry-login REGISTRY_HOST=nexus.example.org REGISTRY_USER=svc-ci REGISTRY_PASSWORD=...
make publish-platform REGISTRY=nexus.example.org/myapp
```

The password goes to `podman login` via stdin, never as a command-line
argument, so it never appears in `ps`/shell history — the same lesson
already applied to `--mirror`'s Nexus credentials above. Once logged in,
podman's credential cache covers every subsequent `build`/`pull`/`push` in
the same shell — no other script needs to know about it.

See [`docs/gitlab-ci.md`](gitlab-ci.md) for how this fits into CI.

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

### Reading the automatic network/TLS hint

`scripts/fetch-artifacts.sh` and `scripts/vm-bootstrap-perlbrew.sh` print a
targeted hint automatically when a failure looks network/TLS-related — no
need to guess from a raw `curl` error. The Containerfile's `microdnf`
installs and `Containerfile.deps`'s `cpanm`/`carton install` print an
equivalent line before failing the build. It stays silent for anything
unrelated (a hash mismatch, a missing file), so if you don't see it, the
failure is something else. The exit code in the message tells you which
half of the setup to check:

| Exit code                          | Meaning                                    | Check                                                                                                                                                   |
| ---------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `6`, `7`, `28`                     | Can't resolve/reach the host, or timed out | `http_proxy`/`https_proxy`/`no_proxy` — is the proxy set, correct, and actually reachable from here?                                                    |
| `35`, `51`, `60`, `77`, `82`, `83` | Certificate/CA problem                     | `VM_CA_CERT` (VM path) / `CURL_CA_BUNDLE` or your system's trust store (host path) / `certs/` (container path) — does it trust the proxy's certificate? |

`vm-bootstrap-perlbrew.sh`'s hint can also appear for a non-curl exit code —
perlbrew wraps its own internal fetches (patchperl, Perl source) in its own
exit status rather than curl's, so the script also recognizes the failure by
the command that ran, not just the code.
