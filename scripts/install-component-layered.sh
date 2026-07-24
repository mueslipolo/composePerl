#!/usr/bin/env bash
set -euo pipefail

# install-component-layered.sh - install a component's delta on top of common
#
# The install half of the multi-component model (docs/multi-component.md). A
# component's dev image is FROM common-dev, so the shared common modules are
# already present at <common-lib>. This installs the component's modules into a
# SEPARATE <out-lib> that carries ONLY the delta, so the runtime image can COPY
# the shared common layer once and each component's small delta layer on top.
#
# Strategy: SEED-THEN-DELTA.
#   cpm's -L is a *contained* local::lib: it ignores the ambient PERL5LIB, but
#   it DOES treat modules already present in the -L target itself as satisfied
#   (both verified against real cpm). So:
#     1. seed <out-lib> with a copy of <common-lib>;
#     2. cpm install the component from its DELTA-only vendor mirror into that
#        seeded lib — cpm sees the shared deps as installed and installs only
#        the delta (no re-resolving or recompiling common's XS);
#     3. prune every file <common-lib> already provides, leaving <out-lib> with
#        just the delta.
#   The prune is SAFE because the BOM gate pins shared distributions to the same
#   version, so the seeded files are byte-identical to common's. Net: small
#   delta-only bundles, common's XS compiled once, and a delta-only runtime layer.
#
# Usage:   install-component-layered.sh <component-workdir> <common-lib> <out-lib>
#            <component-workdir>  a dir with cpanfile + vendor/cache (as unpacked
#                                 from a `make bundle-component` bundle)
#            <common-lib>         the already-installed common lib (has lib/perl5)
#            <out-lib>            target for the component's delta
# Env:     CPM   - cpm binary (default: cpm on PATH)
# Exit:    0 installed; 2 usage / missing inputs / tools.

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <component-workdir> <common-lib> <out-lib>" >&2
    exit 2
fi
workdir="$1"
common_lib="$2"
out_lib="$3"
CPM="${CPM:-cpm}"

if ! command -v "${CPM}" >/dev/null 2>&1; then echo "ERROR: ${CPM} not on PATH" >&2; exit 2; fi
if [[ ! -f "${workdir}/cpanfile" ]]; then echo "ERROR: ${workdir}/cpanfile not found" >&2; exit 2; fi
if [[ ! -d "${common_lib}/lib/perl5" ]]; then echo "ERROR: ${common_lib} has no lib/perl5" >&2; exit 2; fi

# The bundle should already carry vendor/cache. Only fall back to carton (which
# is not present in the common-dev image) if it doesn't — and only then is
# carton actually required.
if [[ ! -d "${workdir}/vendor/cache" ]]; then
    if ! command -v carton >/dev/null 2>&1; then
        echo "ERROR: ${workdir}/vendor/cache missing and carton not on PATH to build it" >&2
        exit 2
    fi
    echo "==> Vendoring component distributions (carton bundle)..."
    ( cd "${workdir}" && carton bundle >/dev/null )
fi

# 1. Seed the target with common so cpm treats the shared modules as installed.
echo "==> Seeding ${out_lib} from ${common_lib}..."
mkdir -p "${out_lib}"
cp -a "${common_lib}/." "${out_lib}/"

# 2. Install the component's delta into the seeded lib. cpm installs only what
#    the seed doesn't already satisfy — i.e. the delta.
echo "==> Installing component delta into ${out_lib} (cpm, offline)..."
"${CPM}" install -L "${out_lib}" \
    --resolver "02packages,file://${workdir}/vendor/cache" \
    --cpanfile "${workdir}/cpanfile" >/dev/null

# 3. Prune every file the common layer already provides — removing the seed and
#    leaving only the delta. Safe: shared dists are the same version (BOM gate).
echo "==> Pruning files already provided by ${common_lib}..."
pruned=0
while IFS= read -r -d '' f; do
    rel="${f#"${out_lib}/"}"
    if [[ -e "${common_lib}/${rel}" ]]; then
        rm -f "${f}"
        pruned=$((pruned + 1))
    fi
done < <(find "${out_lib}" -type f -print0)
find "${out_lib}" -type d -empty -delete 2>/dev/null || true

echo "==> Done: pruned ${pruned} shared file(s); ${out_lib} now carries only the component delta."
