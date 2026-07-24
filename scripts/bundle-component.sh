#!/usr/bin/env bash
set -euo pipefail

# bundle-component.sh - produce a component's bundle (resolve + gate + bundle)
#
# The per-component counterpart to bundle-common.sh: resolves a component's
# cpanfile against the shared common BOM (enforcing the no-override gate),
# vendors the result, and writes bundles/<component>/bundle-<hash>.tar.gz plus
# its delta list and build-info (docs/multi-component.md).
#
# The bundle carries the component's FULL closure (cpanfile, resolved snapshot,
# vendor/cache, and delta.txt). The component image install is "install full,
# then prune the files common already provides" (see the example component
# Containerfile / install-component-layered.sh), so the runtime layer still
# ends up delta-only; delta.txt records exactly what that delta is.
#
# Usage:   bundle-component.sh <common-dir> <component-dir> [<bundles-root>]
#            <common-dir>     resolved common set (cpanfile + cpanfile.snapshot)
#            <component-dir>  the component (its cpanfile; basename = its name)
#            <bundles-root>   default: <repo>/bundles
# Exit:    0 ok; 1 BOM conflict; 2 usage / missing tools / missing inputs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RESOLVE="${SCRIPT_DIR}/resolve-component.sh"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <common-dir> <component-dir> [<bundles-root>]" >&2
    exit 2
fi
common_dir="$1"
component_dir="$2"
bundles_root="${3:-${PROJECT_ROOT}/bundles}"

if ! command -v carton >/dev/null 2>&1; then echo "ERROR: carton not on PATH (cpanm Carton)" >&2; exit 2; fi
if [[ ! -f "${component_dir}/cpanfile" ]]; then echo "ERROR: ${component_dir}/cpanfile not found" >&2; exit 2; fi

name="$(basename "${component_dir}")"
out_dir="${bundles_root}/${name}"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# 1. Resolve against common + enforce the BOM gate (exit 1 on conflict).
echo "==> Resolving component '${name}' against the common BOM..."
"${RESOLVE}" "${common_dir}" "${component_dir}/cpanfile" "${workdir}"

# 2. Vendor the resolved closure.
echo "==> Vendoring (carton bundle)..."
( cd "${workdir}" && carton bundle >/dev/null )

# 3. Package bundles/<name>/bundle-<hash>.tar.gz (+ delta.txt) + build-info + symlink.
mkdir -p "${out_dir}"
hash="$(sha256sum "${workdir}/cpanfile.snapshot" | cut -c1-12)"
bundle_name="bundle-${hash}.tar.gz"
tar czf "${out_dir}/${bundle_name}" \
    -C "${workdir}" cpanfile cpanfile.snapshot vendor delta.txt
ln -sf "${bundle_name}" "${out_dir}/bundle-latest.tar.gz"

perl_version="$(sed -n 's/^ARG PERL_VERSION=//p' "${PROJECT_ROOT}/Containerfile")"
info_name="bundle-${hash}.build-info"
{
    echo "PERL_VERSION=${perl_version}"
    echo "COMPONENT=${name}"
    echo "COMPONENT_HASH=${hash}"
} > "${out_dir}/${info_name}"
ln -sf "${info_name}" "${out_dir}/bundle-latest.build-info"

echo "==> Component bundle: ${out_dir}/${bundle_name}"
echo "==> Delta: $(grep -c . "${workdir}/delta.txt" || true) distribution(s) unique to '${name}'"
