#!/usr/bin/env bash
set -euo pipefail

# setup.sh - Assemble an isolated container-build workspace.
#
# Creates a temporary directory that looks like a valid project root:
#   - symlinks to the real Containerfile, Containerfile.deps, Makefile,
#     scripts/, and artifacts/ (so we build the actual production
#     Containerfile, not a copy)
#   - copies of the test-specific cpanfile, cpanfile.snapshot, app/, and
#     test-load.pl (so we exercise the tiny curated test cpanfile, not the
#     production 700-module one)
#
# Prints the workspace path on stdout. Callers `cd` into it and run
# `make bundle && make all && make test-load-dev && make test-load-runtime`.
#
# Usage:
#   WORKDIR="$(bash tests/container-build/setup.sh)"
#   cd "$WORKDIR" && make bundle

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

WORKDIR="${WORKDIR:-$(mktemp -d -t container-build-XXXXXX)}"
mkdir -p "${WORKDIR}"

# Symlinks to the real build machinery. podman honours these because they
# reference files inside the build context via absolute paths that the shell
# resolves before podman ever sees them.
ln -sfn "${PROJECT_ROOT}/Containerfile"      "${WORKDIR}/Containerfile"
ln -sfn "${PROJECT_ROOT}/Containerfile.deps" "${WORKDIR}/Containerfile.deps"
ln -sfn "${PROJECT_ROOT}/Makefile"           "${WORKDIR}/Makefile"
ln -sfn "${PROJECT_ROOT}/scripts"            "${WORKDIR}/scripts"

# artifacts/ must be a REAL directory inside the build context — podman does
# not follow symlinks pointing outside its context. Prefer hardlinks (same-fs
# only, essentially free) and fall back to a full copy (~90 MB) otherwise.
# artifacts/ is gitignored, so a fresh checkout that hasn't run
# fetch-artifacts.sh yet won't have it at all (not even empty) — mkdir -p the
# source too, so a missing dir behaves like an empty one instead of crashing
# `cp` under set -e before check-artifacts ever gets a chance to populate it.
mkdir -p "${PROJECT_ROOT}/artifacts"
mkdir -p "${WORKDIR}/artifacts"
if ! cp -al "${PROJECT_ROOT}/artifacts/." "${WORKDIR}/artifacts/" 2>/dev/null; then
    cp -r "${PROJECT_ROOT}/artifacts/." "${WORKDIR}/artifacts/"
fi

# Copies (not symlinks) of the test-specific project files
cp "${SCRIPT_DIR}/cpanfile" "${WORKDIR}/cpanfile"
if [[ -f "${SCRIPT_DIR}/cpanfile.snapshot" ]]; then
    cp "${SCRIPT_DIR}/cpanfile.snapshot" "${WORKDIR}/cpanfile.snapshot"
else
    # Containerfile.deps requires cpanfile.snapshot to exist for its COPY step.
    # An empty file is fine — carton install inside the container will populate
    # it fresh from cpanfile when no snapshot data is present.
    : > "${WORKDIR}/cpanfile.snapshot"
fi
mkdir -p "${WORKDIR}/app"
cp "${SCRIPT_DIR}/app/app.pl"    "${WORKDIR}/app/app.pl"
cp "${SCRIPT_DIR}/test-load.pl"  "${WORKDIR}/test-load.pl"

# test-load-modules.sh mounts these three files into the container; symlink
# them individually so the test workspace picks up any upstream changes.
mkdir -p "${WORKDIR}/tests"
ln -sfn "${PROJECT_ROOT}/tests/module-load-test.pl" "${WORKDIR}/tests/module-load-test.pl"
ln -sfn "${PROJECT_ROOT}/tests/TestConfig.pm"       "${WORKDIR}/tests/TestConfig.pm"
ln -sfn "${PROJECT_ROOT}/tests/test-config.conf"    "${WORKDIR}/tests/test-config.conf"

# Bundle output dir (podman writes bundles/bundle-<hash>.tar.gz here)
mkdir -p "${WORKDIR}/bundles"

# certs/ must exist (even empty) — Containerfile's perl-src and base stages
# both COPY certs/ unconditionally for optional corporate CA trust, and
# podman refuses to COPY a source path that doesn't exist in the build
# context.
mkdir -p "${WORKDIR}/certs"
touch "${WORKDIR}/certs/.gitkeep"

echo "${WORKDIR}"
