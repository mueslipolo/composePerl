#!/usr/bin/env bash
set -euo pipefail

# vm-install-bundle.sh - Install an offline CPAN bundle into a perlbrew lib
#
# Purpose: Makes docs/vm-deployment.md's "Install procedure" real: creates
#          (idempotently) a dedicated perlbrew lib for this component,
#          activates it non-interactively, and installs the bundle's
#          vendor/cache offline via cpm.
# Usage:   vm-install-bundle.sh <bundle-tarball> <bundle-info-file> <lib-name> <cpm-binary>
# Env:     PERLBREW_ROOT - default $HOME/perl5/perlbrew

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <bundle-tarball> <bundle-info-file> <lib-name> <cpm-binary>" >&2
    exit 2
fi

BUNDLE_TARBALL="$1"
BUILD_INFO="$2"
LIB_NAME="$3"
CPM_BIN="$4"
PERLBREW_ROOT="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}"

for f in "${BUNDLE_TARBALL}" "${BUILD_INFO}" "${CPM_BIN}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: required file not found: ${f}" >&2
        exit 1
    fi
done

# PERL_VERSION comes from the bundle's own stamp, not a value copied in by
# hand. Run vm-check-compat.sh against this same file first.
# shellcheck source=/dev/null
source "${BUILD_INFO}"

if [[ -z "${PERL_VERSION:-}" ]]; then
    echo "ERROR: ${BUILD_INFO} did not set PERL_VERSION" >&2
    exit 1
fi

export PATH="${PERLBREW_ROOT}/bin:${PATH}"

# perlbrew always resolves a bare version like "5.28.1" to the installation
# name "perl-5.28.1" internally (confirmed against perlbrew's own source:
# App::perlbrew::resolve_installation_name auto-uplifts it) — every lib it
# creates or lists is named against that resolved form, e.g.
# "perl-5.28.1@myapp", not "5.28.1@myapp". Using the resolved name explicitly
# here, rather than relying on that implicit uplift, keeps the lib-list
# check, lib create, and the on-disk LIB_PATH all in agreement.
PERL_INSTALLATION="perl-${PERL_VERSION}"
FULL_LIB_NAME="${PERL_INSTALLATION}@${LIB_NAME}"

# 1. Create the lib if this is a first-time deploy (idempotent: perlbrew
#    errors if it already exists — check first, don't just ignore the error).
if perlbrew lib list | grep -qF "${FULL_LIB_NAME}"; then
    echo "==> Lib ${FULL_LIB_NAME} already exists"
else
    echo "==> Creating lib ${FULL_LIB_NAME}..."
    perlbrew lib create "${FULL_LIB_NAME}"
fi

# 2. Activate the lib non-interactively. `perlbrew use`/`switch` are shell
#    functions meant for interactive shells; in a script, source perlbrew's
#    own bashrc with the target perl+lib set as env vars instead — this is
#    perlbrew's documented pattern for non-interactive use.
export PERLBREW_PERL="${PERL_INSTALLATION}"
export PERLBREW_LIB="${LIB_NAME}"
# shellcheck source=/dev/null
source "${PERLBREW_ROOT}/etc/bashrc"

# Sanity-check we're actually in the lib we think we are before installing.
perl -v
echo "PERL5LIB=${PERL5LIB:-<unset>}"

if [[ -z "${PERL5LIB:-}" ]]; then
    echo "ERROR: activating ${FULL_LIB_NAME} did not set PERL5LIB" >&2
    exit 1
fi

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
#
#    LIB_PATH is derived from PERL5LIB (what perlbrew's own activation just
#    set), not reconstructed from PERLBREW_ROOT — perlbrew's actual lib
#    storage location is governed by PERLBREW_HOME (default ~/.perlbrew), a
#    DIFFERENT variable from PERLBREW_ROOT. Confirmed the hard way: an
#    earlier version of this script built the path from PERLBREW_ROOT and
#    silently installed the bundle into a directory perlbrew itself was not
#    tracking, leaving the perlbrew-created lib empty.
LIB_PATH="${PERL5LIB%%:*}"
LIB_PATH="${LIB_PATH%/lib/perl5}"
"${CPM_BIN}" install -L "${LIB_PATH}" \
    --cpanfile "${WORKDIR}/cpanfile" \
    --resolver "02packages,file://${WORKDIR}/vendor/cache"

echo "==> Installed bundle into ${LIB_PATH}"
