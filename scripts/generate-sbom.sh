#!/usr/bin/env bash
set -euo pipefail

# generate-sbom.sh - CycloneDX SBOM covering OS packages + CPAN modules
#
# Purpose: Combines syft's OS-package SBOM (from the built runtime image)
#          with scripts/generate-cpan-sbom.pl's CPAN-module SBOM (from
#          cpanfile.snapshot) into one CycloneDX document. See docs/sbom.md
#          for why two generators are needed — no general-purpose SBOM tool
#          has a Perl/CPAN cataloger.
# Usage:   scripts/generate-sbom.sh [output-path]
#          Or via: make sbom
# Needs:   podman, jq; a real `syft` binary on PATH (falls back to running
#          the pinned docker.io/anchore/syft image via podman if absent);
#          Carton + CPAN::DistnameInfo for the CPAN half (this script
#          checks for them and tells you the exact command to run — it
#          won't install them for you silently).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-myapp}"
SYFT_VERSION="1.20.0"

OUTPUT="${1:-${PROJECT_ROOT}/sbom.json}"
CPANFILE_SNAPSHOT="${PROJECT_ROOT}/cpanfile.snapshot"
RUNTIME_IMAGE="${IMAGE_NAME}:runtime"

echo "==> Checking preconditions..."

if ! podman image exists "${RUNTIME_IMAGE}" 2>/dev/null; then
    echo "ERROR: ${RUNTIME_IMAGE} not found. Run 'make runtime' first." >&2
    exit 1
fi

if [[ ! -f "${CPANFILE_SNAPSHOT}" ]]; then
    echo "ERROR: cpanfile.snapshot not found at ${CPANFILE_SNAPSHOT}" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required (used to merge the OS and CPAN SBOM halves)." >&2
    exit 1
fi

if ! perl -MCarton::Snapshot -e1 2>/dev/null || ! perl -MCPAN::DistnameInfo -e1 2>/dev/null; then
    echo "ERROR: Carton::Snapshot and/or CPAN::DistnameInfo not installed." >&2
    echo "       Run: cpanm --notest Carton CPAN::DistnameInfo" >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "==> OS-package half: syft against ${RUNTIME_IMAGE}..."
podman save "${RUNTIME_IMAGE}" -o "${WORKDIR}/image.tar"

if command -v syft >/dev/null 2>&1; then
    syft "docker-archive:${WORKDIR}/image.tar" -o cyclonedx-json > "${WORKDIR}/os-sbom.json"
else
    echo "    (no local syft binary — using docker.io/anchore/syft:v${SYFT_VERSION} via podman)"
    podman run --rm -v "${WORKDIR}/image.tar:/scan.tar:ro" \
        "docker.io/anchore/syft:v${SYFT_VERSION}" "docker-archive:/scan.tar" -o cyclonedx-json \
        > "${WORKDIR}/os-sbom.json"
fi

echo "==> CPAN-module half: generate-cpan-sbom.pl against cpanfile.snapshot..."
perl "${SCRIPT_DIR}/generate-cpan-sbom.pl" "${CPANFILE_SNAPSHOT}" > "${WORKDIR}/cpan-sbom.json"

echo "==> Merging into one CycloneDX document..."
jq -s '.[0].components += .[1].components | .[0]' \
    "${WORKDIR}/os-sbom.json" "${WORKDIR}/cpan-sbom.json" > "${OUTPUT}"

echo "==> Validating merged document..."
jq -e '.bomFormat == "CycloneDX"' "${OUTPUT}" > /dev/null \
    || { echo "ERROR: bomFormat is not CycloneDX" >&2; exit 1; }

cpan_count=$(jq '[.components[] | select(.purl != null and (.purl | startswith("pkg:cpan/")))] | length' "${OUTPUT}")
if [[ "${cpan_count}" -lt 1 ]]; then
    echo "ERROR: expected at least one pkg:cpan/ component, found none" >&2
    exit 1
fi

malformed=$(jq '[.components[] | select(.purl != null and (.purl | startswith("pkg:cpan")) and (.purl | startswith("pkg:cpan/") | not))] | length' "${OUTPUT}")
if [[ "${malformed}" -gt 0 ]]; then
    echo "ERROR: found ${malformed} component(s) with a malformed pkg:cpan purl" >&2
    exit 1
fi

os_count=$(jq '.components | length' "${WORKDIR}/os-sbom.json")
total_count=$(jq '.components | length' "${OUTPUT}")
echo "==> Done: ${OUTPUT} (${os_count} OS + ${cpan_count} CPAN = ${total_count} components)"
