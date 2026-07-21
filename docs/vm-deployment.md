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
  against** already installed under it. Read from the bundle's own
  `.build-info` sibling file, not assumed — see the version-compatibility
  gate below.
- A dedicated **perlbrew lib** per deployed app/component, so this install
  can't collide with another app's modules on the same host and same perl.
  This is the direct VM-side equivalent of one container per component —
  when purpose 2 eventually splits into multiple containers, expect this
  fleet to grow one perlbrew lib per component in parallel, same idea.
- The `cpm` fatpack (`artifacts/cpm` in this repo) staged onto the VM
  alongside the bundle. It's a single self-contained Perl script — no
  install step, no network access required at install time.

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

Plain `KEY=VALUE`, so the deploy job can `source` it directly:

```bash
# On the VM, before installing — fail here, not three steps into cpm install.
source "bundle-${HASH}.build-info"   # sets PERL_VERSION, UBI_IMAGE

perlbrew list | grep -qF "perl-${PERL_VERSION}" || {
    echo "FAIL: perlbrew has no perl-${PERL_VERSION}; this bundle needs it" >&2
    exit 1
}

# UBI_IMAGE records the *container* OS the bundle's compiled-module
# resolution assumed. There's no single command to compare that against an
# arbitrary VM's OS — map UBI_IMAGE's RHEL major version to whatever your
# fleet uses to identify VM OS versions (e.g. `rpm -E %{rhel}` on RHEL/UBI
# family hosts) and gate on that matching before installing.
```

## Install procedure

Run as whatever user owns the perlbrew install and this app's perlbrew lib
— not root, unless your perlbrew install is itself root-owned.

```bash
set -euo pipefail

PERLBREW_ROOT="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}"
LIB_NAME="myapp"              # one lib per deployed component
BUNDLE_TARBALL="bundle-<hash>.tar.gz"   # staged onto the VM by the pipeline
CPM_BIN="./cpm"                          # artifacts/cpm, staged alongside

# PERL_VERSION (and UBI_IMAGE, checked separately — see the gate above) come
# from the bundle's own stamp, not a value copied into this script by hand.
source "bundle-<hash>.build-info"

# 1. Create the lib if this is a first-time deploy (idempotent: perlbrew
#    errors if it already exists — check first, don't just ignore the error).
if ! perlbrew lib list | grep -qF "${PERL_VERSION}@${LIB_NAME}"; then
    perlbrew lib create "${PERL_VERSION}@${LIB_NAME}"
fi

# 2. Activate the lib non-interactively. `perlbrew use`/`switch` are shell
#    functions meant for interactive shells; in a script or CI job, source
#    perlbrew's own bashrc with the target perl+lib set as env vars instead
#    — this is perlbrew's documented pattern for non-interactive use.
export PERLBREW_PERL="${PERL_VERSION}"
export PERLBREW_LIB="${LIB_NAME}"
source "${PERLBREW_ROOT}/etc/bashrc"

# Sanity-check we're actually in the lib we think we are before installing.
perl -v
perl -Mlocal::lib -e 1 2>/dev/null || true   # optional: confirms lib wiring
echo "PERL5LIB=${PERL5LIB:-<unset>}"

# 3. Extract the bundle to a scratch dir.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
tar xzf "${BUNDLE_TARBALL}" -C "${WORKDIR}"

# 4. Drop cpanfile.snapshot before running cpm — same reasoning as the
#    `dev` stage in Containerfile: with the snapshot gone, cpm has nothing
#    to resolve against except vendor/cache, so it can only reproduce
#    exactly what's pinned. Keeping the snapshot around risks cpm resolving
#    a *different* version if vendor/cache ever contains more than one.
rm -f "${WORKDIR}/cpanfile.snapshot"

# 5. Install offline into the active perlbrew lib. cpm defaults to the
#    active local-lib-style environment perlbrew just set up; passing -L
#    explicitly avoids relying on that implicitly in a deploy pipeline.
LIB_PATH="${PERLBREW_ROOT}/libs/${PERL_VERSION}@${LIB_NAME}"
"${CPM_BIN}" install -L "${LIB_PATH}" \
    --cpanfile "${WORKDIR}/cpanfile" \
    --resolver "02packages,file://${WORKDIR}/vendor/cache"
```

Verify `LIB_PATH` against `perlbrew info` on the actual target host before
relying on it in a pipeline — the exact layout has been stable across
perlbrew releases but isn't guaranteed API.

## Verification

Don't build new smoke-test tooling for this — this repo already has one.
`tests/module-load-test.pl` + `tests/TestConfig.pm` + `tests/test-config.conf`
are exactly the container test suite's module-load check, and they don't
know or care that they're running in a container; they just need `cpanfile`
on disk and the right `PERL5LIB`. Point them at the perlbrew lib instead:

```bash
PERL5LIB="${LIB_PATH}/lib/perl5:${PERL5LIB}" \
    perl tests/module-load-test.pl
```

(`module-load-test.pl` currently hardcodes its input paths as `/tmp/cpanfile`
and `/tmp/test-config.conf` to match how the container mounts them — see
`scripts/test-load-modules.sh`. For VM use, either stage copies at those
same paths or adjust the two constants at the top of the script.)

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

This repo's own CI (`.github/workflows/test.yml`) only tests the bundle
generation and container path — it has no deploy job, and deployment is
described here as happening from a separate GitLab pipeline. Concretely,
that pipeline needs to, at minimum:

1. Pull `bundle-<hash>.tar.gz` **and** its `bundle-<hash>.build-info` sibling
   (built by `make bundle` in this repo, however they're published — job
   artifact, package registry, etc.) plus `artifacts/cpm`.
1. Run the version-compatibility gate, then the install procedure above,
   against each target VM.
1. Run the verification step and fail the deploy on any `[FAIL]` line.

The specifics of *how* the GitLab job reaches each VM (SSH, Ansible, a
config-management agent already installed there) aren't assumed here since
they depend on infrastructure this repo doesn't define.
