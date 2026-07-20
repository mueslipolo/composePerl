#!/usr/bin/env bash
set -euo pipefail

# fetch-artifacts.sh - Populate artifacts/ with build inputs
#
# Downloads and hash-verifies the pinned versions of:
#   - Perl source tarball        (cpan.org)
#   - cpanm fatpack              (miyagawa/cpanminus GitHub, pinned tag)
#   - cpm fatpack                (skaji/cpm GitHub, pinned commit)
#   - Oracle Instant Client      (basiclite + SDK, download.oracle.com direct URLs)
#
# Idempotent: skips artifacts already present with the expected sha256.
# Fails loudly on hash mismatch.
#
# Oracle Instant Client is downloaded from Oracle's public direct-download URLs
# (no login required). It is licensed for use but NOT for redistribution — do not
# publish images or artifacts containing it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${PROJECT_ROOT}/artifacts"

PERL_VERSION="${PERL_VERSION:-5.42.2}"

# Pinned URLs + SHA256s. Bump together when upgrading.
# Each *_SHA256 may be overridden by the same-named env var (used by bats tests
# to swap in mock-payload hashes without touching production hashes).
PERL_URL="https://www.cpan.org/src/5.0/perl-${PERL_VERSION}.tar.gz"
PERL_SHA256="${PERL_SHA256:-9384e8deb75b7b1695e5637971b752281aaecd025a3d5d4734d33c1d0adfee47}"

CPANM_VERSION="1.9018"
CPANM_URL="https://raw.githubusercontent.com/miyagawa/cpanminus/App-cpanminus-${CPANM_VERSION}/App-cpanminus/cpanm"
CPANM_SHA256="${CPANM_SHA256:-40366672f40d4e3d6ee62199e0a31e56a890f7d195d14df23662b75eb9fc7c73}"

CPM_COMMIT="bcd688222d9275c0668c215a7cc0f33ed42190d9"
CPM_URL="https://raw.githubusercontent.com/skaji/cpm/${CPM_COMMIT}/cpm"
CPM_SHA256="${CPM_SHA256:-6f5ae6d0e25ba20f768b8856ea61481da9d142a04629d658025011c76d3bbc3f}"

ORACLE_VERSION="23.8.0.25.04"
ORACLE_BASICLITE_URL="https://download.oracle.com/otn_software/linux/instantclient/2380000/instantclient-basiclite-linux.x64-${ORACLE_VERSION}.zip"
ORACLE_BASICLITE_SHA256="${ORACLE_BASICLITE_SHA256:-208bc7a9372efae098ab743d6e76aeb66e6f42579dcdbb7a6a8438412481b02e}"
ORACLE_SDK_URL="https://download.oracle.com/otn_software/linux/instantclient/2380000/instantclient-sdk-linux.x64-${ORACLE_VERSION}.zip"
ORACLE_SDK_SHA256="${ORACLE_SDK_SHA256:-aa5dace6c9c4c9946fe2d989a67937d2a0b7cdcf013849dbe04cd62177efd508}"

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

mkdir -p "${ARTIFACTS_DIR}"

fetch() {
    local url="$1"
    local dest="$2"
    local expected_sha="$3"

    if [[ -f "${dest}" ]]; then
        local actual
        actual="$(sha256sum "${dest}" | awk '{print $1}')"
        if [[ "${actual}" == "${expected_sha}" ]]; then
            echo "==> $(basename "${dest}") already present (sha256 matches, skipping)"
            return 0
        fi
        echo "==> $(basename "${dest}") present but sha256 mismatch, re-downloading"
        echo "    expected: ${expected_sha}"
        echo "    actual:   ${actual}"
        rm -f "${dest}"
    fi

    echo "==> Fetching $(basename "${dest}") from ${url}"
    curl -fSL --retry 3 --retry-delay 2 -o "${dest}.tmp" "${url}"

    local actual
    actual="$(sha256sum "${dest}.tmp" | awk '{print $1}')"
    if [[ "${actual}" != "${expected_sha}" ]]; then
        rm -f "${dest}.tmp"
        echo "ERROR: sha256 mismatch for $(basename "${dest}")" >&2
        echo "    expected: ${expected_sha}" >&2
        echo "    actual:   ${actual}" >&2
        echo "    url:      ${url}" >&2
        echo "" >&2
        echo "If the upstream has legitimately updated, verify the new file and" >&2
        echo "update the pinned hash in $(basename "$0")." >&2
        exit 1
    fi
    mv "${dest}.tmp" "${dest}"
    echo "==> $(basename "${dest}") ok"
}

fetch "${PERL_URL}"              "${ARTIFACTS_DIR}/perl-${PERL_VERSION}.tar.gz"                          "${PERL_SHA256}"
fetch "${CPANM_URL}"             "${ARTIFACTS_DIR}/cpanm"                                                "${CPANM_SHA256}"
fetch "${CPM_URL}"               "${ARTIFACTS_DIR}/cpm"                                                  "${CPM_SHA256}"
fetch "${ORACLE_BASICLITE_URL}"  "${ARTIFACTS_DIR}/instantclient-basiclite-linux.x64-${ORACLE_VERSION}.zip" "${ORACLE_BASICLITE_SHA256}"
fetch "${ORACLE_SDK_URL}"        "${ARTIFACTS_DIR}/instantclient-sdk-linux.x64-${ORACLE_VERSION}.zip"      "${ORACLE_SDK_SHA256}"
chmod +x "${ARTIFACTS_DIR}/cpanm" "${ARTIFACTS_DIR}/cpm"

echo ""
echo "==> Done. Artifacts in ${ARTIFACTS_DIR}:"
ls -la "${ARTIFACTS_DIR}"
