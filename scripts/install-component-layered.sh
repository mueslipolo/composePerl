#!/usr/bin/env bash
set -euo pipefail

# install-component-layered.sh - install a component's delta on top of common
#
# The install half of the multi-component model (docs/multi-component.md). A
# component's dev image is FROM common-dev, so the shared `common` modules are
# already present at <common-lib>. This installs the component's modules into a
# SEPARATE <out-lib> that carries ONLY the delta, so the runtime image can COPY
# the shared common layer once and each component's small delta layer on top.
#
# Why "install full, then prune" rather than "install only the delta":
#   cpm's -L is a *contained* local::lib — it deliberately ignores the ambient
#   PERL5LIB, so it will NOT treat modules already present in <common-lib> as
#   satisfying a dependency (verified: it re-resolves and reinstalls them). So
#   we let cpm install the component's full closure, then delete every file that
#   the common layer already provides. That prune is SAFE because the BOM
#   conflict gate (scripts/bom-gate.pl) guarantees any distribution shared with
#   common is pinned to the SAME version — so the files are byte-identical and
#   the surviving <out-lib> is exactly the delta.
#
# Usage:   install-component-layered.sh <component-workdir> <common-lib> <out-lib>
#            <component-workdir>  resolve-component.sh output: cpanfile (the
#                                 union) + resolved cpanfile.snapshot
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

if ! command -v carton >/dev/null 2>&1; then echo "ERROR: carton not on PATH" >&2; exit 2; fi
if ! command -v "${CPM}" >/dev/null 2>&1;  then echo "ERROR: ${CPM} not on PATH" >&2; exit 2; fi
if [[ ! -f "${workdir}/cpanfile" ]]; then echo "ERROR: ${workdir}/cpanfile not found" >&2; exit 2; fi
if [[ ! -d "${common_lib}/lib/perl5" ]]; then echo "ERROR: ${common_lib} has no lib/perl5" >&2; exit 2; fi

# 1. Vendor the component's resolved distributions into a local mirror (if the
#    caller hasn't already). carton bundle reads cpanfile.snapshot.
if [[ ! -d "${workdir}/vendor/cache" ]]; then
    echo "==> Bundling component distributions (carton bundle)..."
    ( cd "${workdir}" && carton bundle >/dev/null )
fi

# 2. Install the component's FULL closure into out-lib from the local mirror.
echo "==> Installing component closure into ${out_lib} (cpm, offline)..."
"${CPM}" install -L "${out_lib}" \
    --resolver "02packages,file://${workdir}/vendor/cache" \
    --cpanfile "${workdir}/cpanfile" >/dev/null

# 3. Prune every file the common layer already provides — leaving only the delta.
#    Safe: the BOM gate guarantees shared distributions are the same version, so
#    these files are identical to common's.
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
