#!/usr/bin/env bash
set -euo pipefail

# bundle-common.sh - resolve + bundle the shared "common" CPAN set (host carton)
#
# Produces the common BOM bundle the multi-component platform is built on
# (docs/multi-component.md): resolves common/cpanfile, vendors its
# distributions, and writes bundles/common/bundle-<hash>.tar.gz (+ .build-info
# and a bundle-latest symlink), the same content-addressing the single-component
# path uses. Host-based (runs carton directly) — the container path (deps.sh in
# the carton-runner) is the production equivalent; this is the tested reference
# and a local-dev entry point.
#
# Usage:   bundle-common.sh [<common-dir>] [<bundles-root>]
#            <common-dir>    default: common
#            <bundles-root>  default: bundles
# Exit:    0 ok; 2 usage / missing tools / missing cpanfile.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
common_dir="${1:-${PROJECT_ROOT}/common}"
bundles_root="${2:-${PROJECT_ROOT}/bundles}"

if ! command -v carton >/dev/null 2>&1; then echo "ERROR: carton not on PATH (cpanm Carton)" >&2; exit 2; fi
if [[ ! -f "${common_dir}/cpanfile" ]]; then echo "ERROR: ${common_dir}/cpanfile not found" >&2; exit 2; fi

echo "==> Resolving common set (carton install) in ${common_dir}..."
( cd "${common_dir}" && carton install && carton bundle >/dev/null )

hash="$(sha256sum "${common_dir}/cpanfile.snapshot" | cut -c1-12)"
out="${bundles_root}/common"
mkdir -p "${out}"
name="bundle-${hash}.tar.gz"
tar czf "${out}/${name}" -C "${common_dir}" cpanfile cpanfile.snapshot vendor
ln -sf "${name}" "${out}/bundle-latest.tar.gz"
# Record what this common set was resolved against (Perl comes from Containerfile).
perl_version="$(sed -n 's/^ARG PERL_VERSION=//p' "${PROJECT_ROOT}/Containerfile")"
{
    echo "PERL_VERSION=${perl_version}"
    echo "COMMON_HASH=${hash}"
} > "${out}/bundle-${hash}.build-info"
ln -sf "bundle-${hash}.build-info" "${out}/bundle-latest.build-info"

echo "==> common bundle: ${out}/${name}"
echo "==> $(grep -cE '^  [A-Za-z]' "${common_dir}/cpanfile.snapshot") distribution(s) pinned in the common BOM"
