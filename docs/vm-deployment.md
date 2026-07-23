# Deploying a CPAN bundle to a legacy VM (perlbrew)

This repo does two jobs. This doc covers the first one end to end; see the
root [README](../README.md) for the second.

1. **CPAN dependency management for the legacy VM fleet** — `cpanfile` +
   `cpanfile.snapshot` + `make bundle` produce a hash-pinned, offline CPAN
   mirror (`bundles/bundle-<hash>.tar.gz`). That bundle is the deliverable;
   this doc is how it gets installed onto a perlbrew-managed VM.
1. **The future containerized system** — the same bundle, consumed instead
   by the `dev` stage of `Containerfile`. Covered in the README, not here.

Both consume the exact same bundle artifact. Nothing about the bundle format
is container-specific — it's `vendor/cache` (a local CPAN mirror), `cpanfile`,
and `cpanfile.snapshot`, and it's installed the same way in both places: `cpm`
pointed at the local mirror, snapshot removed first. This doc mirrors that
recipe for a perlbrew target instead of a container `COPY`.

## Prerequisites on the VM

- `perlbrew` installed, with the **same Perl version the bundle was resolved
  against** already installed under it. `scripts/vm-bootstrap-perlbrew.sh <perl-version> [local-perl-tarball]` does this — idempotently (skips
  perlbrew's own install if already present, skips the Perl install if that
  version already exists), and behind a proxy/custom CA if the VM needs one
  (see below). Pass this repo's own `artifacts/perl-<version>.tar.gz` as the
  optional local tarball to install fully offline; omit it to let perlbrew
  fetch the source itself.
- A dedicated **perlbrew lib** per deployed app/component, so this install
  can't collide with another app's modules on the same host and same perl.
  This is the direct VM-side equivalent of one container per component —
  when purpose 2 eventually splits into multiple containers, expect this
  fleet to grow one perlbrew lib per component in parallel, same idea.
  `scripts/vm-install-bundle.sh` (below) creates this for you.
- The `cpm` fatpack (`artifacts/cpm` in this repo) staged onto the VM
  alongside the bundle. It's a single self-contained Perl script — no
  install step, no network access required at install time.

### Enterprise proxy and custom CA

`scripts/vm-bootstrap-perlbrew.sh` is the only step here that touches the
network (perlbrew's own installer, and optionally perlbrew's Perl-source
fetch), so it's the only one that needs proxy/CA awareness:

- `http_proxy`/`https_proxy`/`no_proxy` (or the uppercase form — folded in
  automatically) get exported before perlbrew's installer runs, the same
  convention every other network-touching script in this repo uses. See
  [`docs/proxy.md`](proxy.md) for the full rationale.
- `VM_CA_CERT=/path/to/corp-ca.pem` installs a custom CA into the VM's trust
  store (RHEL-family `update-ca-trust`, matching this fleet's UBI/RHEL
  baseline) before anything is fetched — the VM-side equivalent of the
  Containerfile's `certs/` mechanism, for a TLS-inspecting corporate proxy.
  This is a distinct concern from the proxy vars above: the proxy vars make
  traffic *reach* the proxy, the CA cert makes TLS *validation succeed* once
  a TLS-inspecting proxy is in the path. A corporate proxy usually needs
  both.

Both are verified against a **real** TLS-inspecting proxy, not a mock — a
plain CONNECT-tunnel proxy never touches the TLS bytes, so it can't prove CA
trust matters at all. `tests/mitm-proxy/` is a genuine MITM proxy (terminates
the client's TLS with a leaf cert signed by a throwaway test CA, then makes a
real TLS connection upstream) used by both the `vm-deployment` and
`enterprise-proxy` CI jobs: each runs a negative case (proxy set, CA not
trusted — must fail) and a positive case (CA trusted — must succeed and real
content flows through), so the test can't pass by accident. The
`enterprise-proxy` job covers `scripts/fetch-artifacts.sh` and the
Containerfile's `microdnf` installs the same way; see
[`tests/mitm-proxy/README.md`](../tests/mitm-proxy/README.md).

## The bundle contract

`make bundle` in this repo produces `bundles/bundle-<hash>.tar.gz`, where
`<hash>` is the first 12 hex characters of `sha256(cpanfile.snapshot)` — the
same hash `status.sh` and the image labels use. Inside the tarball:

```
vendor/cache/        # offline CPAN mirror — every pinned distribution's tarball
cpanfile
cpanfile.snapshot
```

Alongside it, not inside it, is `bundle-<hash>.build-info` — see the gate
below. Whatever moves the bundle from CI to the VM (GitLab job artifacts, a
package registry, rsync, Ansible — this doc doesn't assume which) needs to
carry **both files**, keeping the same `<hash>` in both filenames, so the
gate can actually find its pair.

## Version-compatibility gate — check this before installing

`cpanfile.snapshot` pins exact distribution versions, several of them
compiled XS modules (`DBD::Oracle`, `DBD::Pg`, `JSON::XS`, `Moose`, …). Two
things have to match for those to build and behave correctly, not one: the
**Perl version** they were resolved against, and the **OS** they were
resolved under (glibc/OpenSSL, via the UBI base image) — an XS module
compiled against RHEL 9's glibc doesn't just "probably work" on RHEL 8, it's
the same class of ABI mismatch the README's own "Targeting Different
RHEL/UBI Versions" section warns about for the container path.

`make bundle` now stamps both alongside the tarball: every
`bundle-<hash>.tar.gz` has a sibling `bundle-<hash>.build-info` (symlinked
as `bundle-latest.build-info`, same pattern as the tarball itself),
containing:

```
PERL_VERSION=5.28.1
UBI_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:9.6
```

Plain `KEY=VALUE`, so `scripts/vm-check-compat.sh` can `source` it directly:

```bash
# On the VM, before installing — fail here, not three steps into cpm install.
scripts/vm-check-compat.sh "bundle-${HASH}.build-info"
```

It checks both: `perlbrew list` has `perl-${PERL_VERSION}`, and — when
`UBI_IMAGE` is present and the VM exposes `rpm -E %{rhel}` — that the VM's
RHEL major matches the one the bundle's XS modules were compiled against.
It's covered by `tests/bats/vm-check-compat.bats` (mocked) and by the
`vm-deployment` CI job (for real, against a live UBI9 container).

## Install procedure

Run as whatever user owns the perlbrew install and this app's perlbrew lib
— not root, unless your perlbrew install is itself root-owned.

```bash
scripts/vm-install-bundle.sh \
    "bundle-${HASH}.tar.gz" \
    "bundle-${HASH}.build-info" \
    myapp \
    ./cpm
```

`LIB_NAME` (`myapp` above — one per deployed component) is the only value
you choose; everything else — `PERL_VERSION`, the perlbrew lib's actual
on-disk name and location, the extract/cleanup, dropping `cpanfile.snapshot`
before `cpm install` — comes from the bundle's own build-info or is handled
by the script. Two things worth knowing if you ever need to poke around by
hand, both found by actually running this against a real perlbrew install,
not assumed from perlbrew's docs:

- perlbrew always resolves a bare version like `5.28.1` to the installation
  name `perl-5.28.1` internally, so the lib perlbrew actually creates is
  named `perl-${PERL_VERSION}@${LIB_NAME}`, not `${PERL_VERSION}@${LIB_NAME}`.
- The lib's actual on-disk location is governed by **`PERLBREW_HOME`**
  (default `~/.perlbrew`) — a **different variable from `PERLBREW_ROOT`**
  (default `~/perl5/perlbrew`, where the Perl installations themselves
  live). Building the lib path from `PERLBREW_ROOT` — the natural-seeming
  guess — silently installs into a directory perlbrew itself isn't
  tracking, leaving the perlbrew-created lib empty. `vm-install-bundle.sh`
  sidesteps the whole question by reading `PERL5LIB` back from perlbrew's
  own activation (`source .../etc/bashrc` with `PERLBREW_PERL`/
  `PERLBREW_LIB` set) rather than reconstructing the path itself.

Covered by `tests/bats/vm-install-bundle.bats` (mocked perlbrew/cpm) and the
`vm-deployment` CI job (a real `cpm install` against a real bundle).

## Verification

Don't build new smoke-test tooling for this — this repo already has some.
`tests/module-load-test.pl` + `tests/TestConfig.pm` + `tests/test-config.conf`
are exactly the container test suite's module-load check, and they don't
know or care that they're running in a container; they just need `cpanfile`
on disk and the right `PERL5LIB`. Point them at the perlbrew lib instead:

```bash
export PERLBREW_PERL="perl-${PERL_VERSION}"
export PERLBREW_LIB="myapp"
source "${PERLBREW_ROOT}/etc/bashrc"   # sets PERL5LIB for this lib — see above
perl tests/module-load-test.pl
```

(`module-load-test.pl` currently hardcodes its input paths as `/tmp/cpanfile`
and `/tmp/test-config.conf` to match how the container mounts them — see
`scripts/test-load-modules.sh`. For VM use, either stage copies at those
same paths or adjust the two constants at the top of the script.)

For a functional check, not just a `require` loop, `tests/container-build/test-load.pl`
actually uses a bundled module and asserts a version bound — the
`vm-deployment` CI job runs both against a real perlbrew-installed bundle on
every push.

## Rollback

Because the bundle hash is content-addressed, keep the previous hash's
perlbrew lib around instead of overwriting a lib in place:

```
perl-5.28.1@myapp-<old-hash>
perl-5.28.1@myapp-<new-hash>
```

Rolling back is then re-pointing whatever wraps the app (a systemd unit's
`PERL5LIB`, an app-server config, etc.) at the previous lib's path — no
reinstall needed. This is the direct analogue of the container image
tagging scheme (`myapp:dev-<hash>` alongside the moving `myapp:dev` tag) —
same lineage-by-hash idea, perlbrew-lib-shaped instead of image-tag-shaped.
Prune old libs on your own retention schedule; this doc doesn't assume one.

## Where this fits in the pipeline

This repo's own CI (`.github/workflows/test.yml`) has a `vm-deployment` job
that exercises this entire doc end to end on every push: it builds a real
bundle, boots a container standing in for a bare legacy VM, runs
`scripts/vm-bootstrap-perlbrew.sh` (twice — once offline with a local Perl
tarball, once through a throwaway local proxy to prove the proxy path
actually works), then `vm-check-compat.sh` and `vm-install-bundle.sh` for
real, then both verification scripts. It has no deploy job, though —
deployment to your actual fleet is described here as happening from a
separate GitLab pipeline. Concretely, that pipeline needs to, at minimum:

1. Pull `bundle-<hash>.tar.gz` **and** its `bundle-<hash>.build-info` sibling
   (built by `make bundle` in this repo, however they're published — job
   artifact, package registry, etc.) plus `artifacts/cpm`.
1. Run `scripts/vm-bootstrap-perlbrew.sh` (once per VM, idempotent — skips
   work that's already done), then `scripts/vm-check-compat.sh` and
   `scripts/vm-install-bundle.sh` against each target VM.
1. Run the verification step and fail the deploy on any `[FAIL]` line.

The specifics of *how* the GitLab job reaches each VM (SSH, Ansible, a
config-management agent already installed there) aren't assumed here since
they depend on infrastructure this repo doesn't define.
