#!/usr/bin/env bash
set -euo pipefail

# resolve-component.sh - resolve a component's CPAN deps against the common BOM
#
# The resolution core of the multi-component model (docs/multi-component.md,
# roadmap step 1). Given the `common` BOM (a resolved cpanfile.snapshot) and a
# component's own cpanfile, it:
#   1. assembles a scratch workdir with the UNION cpanfile (common + component)
#      and a copy of common's snapshot as the frozen seed;
#   2. runs `carton install`, which keeps common's pins for everything they
#      satisfy and resolves only the component's genuinely-new distributions;
#   3. runs the conflict gate (scripts/bom-gate.pl) — Carton will *silently*
#      bump a shared pin if the component demands a higher version and exit 0,
#      so the gate re-checks the resolved snapshot and fails hard on any
#      divergence from common;
#   4. on success, writes the component's DELTA (the distributions it adds that
#      common doesn't pin) to <out-dir>/delta.txt.
#
# Usage:   resolve-component.sh <common-dir> <component-cpanfile> <out-dir>
#            <common-dir>          dir containing cpanfile + cpanfile.snapshot
#            <component-cpanfile>  the component's cpanfile
#            <out-dir>             created/overwritten; holds the resolved
#                                  cpanfile.snapshot, local/, and delta.txt
# Exit:    0 resolved cleanly (delta.txt written)
#          1 BOM conflict (component re-pins a shared distribution)
#          2 usage / missing inputs / carton not available
#
# Not yet wired into `make` — the container-based bundle path (deps.sh) will
# call this inside the carton-runner once the common/ + components/ layout
# lands. Standalone and host-runnable so it can be tested directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/bom-gate.pl"

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <common-dir> <component-cpanfile> <out-dir>" >&2
    exit 2
fi
common_dir="$1"
component_cpanfile="$2"
out_dir="$3"

if ! command -v carton >/dev/null 2>&1; then
    echo "ERROR: carton not found on PATH (cpanm Carton)" >&2
    exit 2
fi
for f in "${common_dir}/cpanfile" "${common_dir}/cpanfile.snapshot" "${component_cpanfile}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: required file not found: ${f}" >&2
        exit 2
    fi
done

mkdir -p "${out_dir}"

# 1. Union cpanfile + seeded snapshot (the "merge").
cat "${common_dir}/cpanfile" "${component_cpanfile}" > "${out_dir}/cpanfile"
cp "${common_dir}/cpanfile.snapshot" "${out_dir}/cpanfile.snapshot"

# 2. Resolve. Carton keeps the seeded pins it can satisfy and adds the rest.
echo "==> Resolving component against the common BOM (carton install)..."
( cd "${out_dir}" && carton install )

# 3. Enforce the BOM: fail hard if any shared distribution's version moved.
echo "==> Checking component against the common BOM..."
if ! perl "${GATE}" "${common_dir}/cpanfile.snapshot" "${out_dir}/cpanfile.snapshot" > "${out_dir}/delta.txt"; then
    rm -f "${out_dir}/delta.txt"
    echo "ERROR: component conflicts with the common BOM — see the report above." >&2
    exit 1
fi

# 4. Report the delta (what the component's own bundle would vendor).
delta_count=$(grep -c . "${out_dir}/delta.txt" || true)
echo "==> OK: ${delta_count} delta distribution(s) → ${out_dir}/delta.txt"
