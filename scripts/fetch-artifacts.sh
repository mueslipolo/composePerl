#!/usr/bin/env bash
# fetch-artifacts.sh - Download build artifacts into artifacts/ with hash pinning.
#
# Design:
#   - Versions are defined ONCE: Perl version is read from the Containerfile
#     (ARG PERL_VERSION); tool/Oracle versions are defined below.
#   - Hashes are NOT hardcoded here. They live in a committed lockfile
#     (artifacts.sha256). On first sight of an artifact, its hash is verified
#     against an independent source where one exists (MetaCPAN for the Perl
#     tarball), then recorded ("pinned"). Every later run verifies against
#     the lockfile — any divergence is a hard error.
#   - Bumping a version therefore requires NO edit to this script: change the
#     version, run `make fetch-artifacts` (or let check-artifacts trigger it),
#     and commit the new lockfile line it prints.
#
# To deliberately re-pin an artifact (e.g. upstream legitimately re-released):
#   delete its line from artifacts.sha256 and re-run.

set -Eeuo pipefail

# --- Mode ----------------------------------------------------------------------
# --mirror: fetch from the real public sources (always, ignoring NEXUS_URL for
# the source side) and upload each verified artifact into Nexus afterward —
# the operation that POPULATES the Nexus mirror. Default (no flag): a plain
# fetch, redirected to Nexus instead of the public internet when NEXUS_URL is
# set. See docs/proxy.md.
MIRROR_MODE=0
for arg in "$@"; do
    case "${arg}" in
        --mirror) MIRROR_MODE=1 ;;
        *)
            echo "ERROR: unrecognized argument: ${arg}" >&2
            echo "Usage: $0 [--mirror]" >&2
            exit 2
            ;;
    esac
done

# --- Proxy ---------------------------------------------------------------------
# curl (used for every download below) reads lowercase http_proxy/https_proxy/
# no_proxy. It deliberately does NOT read uppercase HTTP_PROXY for plain http://
# requests (the 2016 "httpoxy" CVE), but does read HTTPS_PROXY — moot here since
# every URL below is https anyway. Some corporate environments only export the
# uppercase form, so fold that in as a fallback rather than requiring users to
# know which casing curl actually wants.
: "${http_proxy:=${HTTP_PROXY:-}}"
: "${https_proxy:=${HTTPS_PROXY:-}}"
: "${no_proxy:=${NO_PROXY:-}}"
export http_proxy https_proxy no_proxy
if [ -n "${https_proxy}" ] || [ -n "${http_proxy}" ]; then
    echo "==> Proxy: https_proxy=${https_proxy:-<unset>} http_proxy=${http_proxy:-<unset>} no_proxy=${no_proxy:-<unset>}"
else
    echo "==> No proxy configured (http_proxy/https_proxy unset)"
fi

# Prints a targeted hint if the failure that just aborted the script (under
# set -e) looks network/TLS-related, so a raw curl error doesn't require
# re-deriving "is this a proxy problem?" by hand. Silent for anything else
# (a hash mismatch, a missing file) — it can't misdirect if it only speaks
# up for the failures it actually recognizes.
_diagnose_network_failure() {
    local exit_code="$1" failing_cmd="$2"
    case "${exit_code}" in
        6|7|28|35|51|52|55|56|58|60|77|82|83) ;;  # curl network/TLS exit codes
        *) return 0 ;;
    esac
    echo "" >&2
    echo "==> Network/TLS error (exit ${exit_code}) while running: ${failing_cmd}" >&2
    echo "    If you're behind a corporate proxy, check:" >&2
    echo "      - http_proxy / https_proxy / no_proxy are set and correct" >&2
    echo "      - your CA trust store (CURL_CA_BUNDLE or your system's) trusts the proxy" >&2
    echo "    See docs/proxy.md for details." >&2
}
trap '_diagnose_network_failure $? "$BASH_COMMAND"' ERR

# --- Locations ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACTS_DIR="${REPO_ROOT}/artifacts"
LOCKFILE="${REPO_ROOT}/artifacts.sha256"
CONTAINERFILE="${REPO_ROOT}/Containerfile"

# --- Versions ----------------------------------------------------------------
# Perl: single source of truth is the Containerfile.
PERL_VERSION="$(sed -n 's/^ARG PERL_VERSION=//p' "${CONTAINERFILE}")"
if [ -z "${PERL_VERSION}" ]; then
    echo "ERROR: could not read ARG PERL_VERSION from ${CONTAINERFILE}" >&2
    exit 1
fi

# Tools: pin to release tags so URLs are immutable and hashes stay stable.
# ("latest" URLs change over time and would fight the hash pinning.)
CPANM_VERSION="1.7048"
CPM_VERSION="0.997024"

# Oracle Instant Client (Linux x64).
# Oracle URLs include a version subdirectory: the version digits collapsed,
# sometimes with a v2 suffix (e.g. 23.26.2.0.0 -> 2326200v2, 21.22.0.0.0 ->
# 2122000). When bumping ORACLE_IC_VERSION, update ORACLE_IC_SUBDIR to match
# the link shown on:
#   https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html
# NOTE: Oracle delists old versions; only recent releases stay downloadable.
ORACLE_IC_VERSION="23.8.0.25.04"
ORACLE_IC_SUBDIR="2380000"

# --- Nexus (optional artifact mirror) ------------------------------------------
# NEXUS_URL set (without --mirror): fetch artifacts from Nexus instead of the
# public internet — for environments without direct internet egress. Unset:
# unchanged, fetch from the public internet (default; zero-config for
# local/GitHub Actions usage). --mirror: see "Mode" above.
#
# ASSUMPTION (correct once real org access exists): a single Nexus 3
# raw-hosted repository, default name "raw-hosted", artifacts under a
# composeperl/ subpath keyed by the same filenames already used in
# artifacts/ and artifacts.sha256. Nexus's raw-format upload is a plain
# authenticated PUT to <nexus>/repository/<repo>/<path>, i.e. exactly what
# `curl --upload-file` sends.
NEXUS_URL="${NEXUS_URL:-}"
NEXUS_REPOSITORY="${NEXUS_REPOSITORY:-raw-hosted}"
NEXUS_USER="${NEXUS_USER:-}"
NEXUS_PASSWORD="${NEXUS_PASSWORD:-}"
NEXUS_BASE_URL="${NEXUS_URL:+${NEXUS_URL}/repository/${NEXUS_REPOSITORY}/composeperl}"

if [ "${MIRROR_MODE}" -eq 1 ]; then
    if [ -z "${NEXUS_URL}" ] || [ -z "${NEXUS_USER}" ] || [ -z "${NEXUS_PASSWORD}" ]; then
        echo "ERROR: --mirror requires NEXUS_URL, NEXUS_USER, and NEXUS_PASSWORD to all be set." >&2
        exit 1
    fi
fi

# --- URLs --------------------------------------------------------------------
# Public (real) sources — always used by --mirror; used by default too unless
# NEXUS_URL redirects them below.
PUBLIC_PERL_URL="https://www.cpan.org/src/5.0/perl-${PERL_VERSION}.tar.gz"
PUBLIC_CPANM_URL="https://raw.githubusercontent.com/miyagawa/cpanminus/${CPANM_VERSION}/cpanm"
PUBLIC_CPM_URL="https://raw.githubusercontent.com/skaji/cpm/${CPM_VERSION}/cpm"
PUBLIC_ORACLE_BASE_URL="https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_IC_SUBDIR}"
ORACLE_BASICLITE_ZIP="instantclient-basiclite-linux.x64-${ORACLE_IC_VERSION}.zip"
ORACLE_SDK_ZIP="instantclient-sdk-linux.x64-${ORACLE_IC_VERSION}.zip"

if [ "${MIRROR_MODE}" -eq 1 ] || [ -z "${NEXUS_URL}" ]; then
    PERL_URL="${PUBLIC_PERL_URL}"
    CPANM_URL="${PUBLIC_CPANM_URL}"
    CPM_URL="${PUBLIC_CPM_URL}"
    ORACLE_BASE_URL="${PUBLIC_ORACLE_BASE_URL}"
else
    echo "==> NEXUS_URL set: fetching artifacts from Nexus (${NEXUS_BASE_URL}/) instead of the public internet"
    PERL_URL="${NEXUS_BASE_URL}/perl-${PERL_VERSION}.tar.gz"
    CPANM_URL="${NEXUS_BASE_URL}/cpanm-${CPANM_VERSION}"
    CPM_URL="${NEXUS_BASE_URL}/cpm-${CPM_VERSION}"
    ORACLE_BASE_URL="${NEXUS_BASE_URL}"
fi

# --- Helpers -------------------------------------------------------------------

sha256_of() {
    sha256sum "$1" | cut -d' ' -f1
}

lockfile_hash_for() {
    # Prints the pinned hash for a filename, or nothing if not pinned.
    # Never returns non-zero: "not pinned" is a value, not an error, and a
    # non-zero return here would kill the script under `set -e` when used
    # in a plain assignment.
    local name="$1"
    [ -f "${LOCKFILE}" ] || return 0
    grep -E "^[0-9a-f]{64}  ${name}\$" "${LOCKFILE}" | head -1 | cut -d' ' -f1 || true
    return 0
}

metacpan_perl_sha256() {
    # Independent source for the Perl tarball hash. Prints hash or nothing.
    # Never returns non-zero: under `set -e` a failing lookup must not kill
    # the script before the caller's fail-closed error path can run.
    local version="$1" response hash
    if ! response="$(curl -fsSL -X POST 'https://fastapi.metacpan.org/v1/release/_search' \
            -H 'Content-Type: application/json' \
            -d "{\"query\":{\"term\":{\"name\":\"perl-${version}\"}},\"fields\":[\"name\",\"checksum_sha256\"],\"size\":1}" 2>&1)"; then
        echo "    (MetaCPAN request failed: ${response})" >&2
        return 0
    fi
    hash="$(printf '%s' "${response}" \
        | grep -o '"checksum_sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]\{64\}"' \
        | head -1 | grep -o '[0-9a-f]\{64\}' || true)"
    printf '%s' "${hash}"
    return 0
}

cpan_checksums_sha256() {
    # Fallback source: the CHECKSUMS index in the same CPAN directory as the
    # tarball. It is PGP-signed by PAUSE (signature not verified here — for
    # full rigor check it manually with gpg). Prints hash or nothing; never
    # returns non-zero.
    local filename="$1" response hash
    if ! response="$(curl -fsSL 'https://www.cpan.org/src/5.0/CHECKSUMS' 2>&1)"; then
        echo "    (CPAN CHECKSUMS request failed: ${response})" >&2
        return 0
    fi
    # CHECKSUMS is a Perl data structure:
    #   'perl-5.28.1.tar.gz' => { ... 'sha256' => '<hash>', ... },
    # Scope to the file's block and match the exact 'sha256' key (there is
    # also a 'sha256-ungz' key to avoid).
    hash="$(printf '%s' "${response}" | awk -v f="'${filename}'" '
        index($0, f) { inblock=1 }
        inblock && /'\''sha256'\''[[:space:]]*=>/ {
            if (match($0, /[0-9a-f]{64}/)) { print substr($0, RSTART, RLENGTH); exit }
        }
        inblock && /},/ { inblock=0 }
    ' || true)"
    printf '%s' "${hash}"
    return 0
}

download() {
    # download <url> <dest>  — skips if dest already exists (verification of
    # existing files still happens in verify_or_learn).
    local url="$1" dest="$2"
    if [ -f "${dest}" ]; then
        echo "==> Already present: $(basename "${dest}") (will verify)"
        return 0
    fi
    echo "==> Fetching $(basename "${dest}") from ${url}"
    # Constrain both the initial request and any redirect to https. Without
    # --proto-redir, -L would happily follow an https URL down to plain http;
    # for a not-yet-pinned artifact that redirect target would be recorded as
    # the trusted hash on first sight (TOFU), so http must never be reachable.
    curl -fL --proto '=https' --proto-redir '=https' --retry 3 -o "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"
}

verify_or_learn() {
    # verify_or_learn <file> [independent-hash] [source-label]
    #
    # If the file is pinned in the lockfile: enforce the pin (hard error on
    # mismatch). If not pinned: verify against the independent hash when one
    # is provided, then pin; otherwise pin on first sight (TOFU) with a
    # notice. Either way, a new pin means the lockfile changed — commit it.
    local file="$1" independent="${2:-}" source_label="${3:-published source}"
    local name actual pinned
    name="$(basename "${file}")"
    actual="$(sha256_of "${file}")"
    pinned="$(lockfile_hash_for "${name}")"

    if [ -n "${pinned}" ]; then
        if [ "${actual}" != "${pinned}" ]; then
            echo "ERROR: sha256 mismatch for ${name}" >&2
            echo "    expected (artifacts.sha256): ${pinned}" >&2
            echo "    actual:                      ${actual}" >&2
            echo "If the upstream has legitimately updated, delete the ${name}" >&2
            echo "line from artifacts.sha256 and re-run to re-pin." >&2
            exit 1
        fi
        echo "    verified: ${name}"
        return 0
    fi

    if [ -n "${independent}" ]; then
        if [ "${actual}" != "${independent}" ]; then
            echo "ERROR: downloaded ${name} does not match its published checksum" >&2
            echo "    published (${source_label}): ${independent}" >&2
            echo "    actual:    ${actual}" >&2
            echo "Refusing to pin. Investigate before retrying (proxy tampering," >&2
            echo "corrupted download, or wrong URL)." >&2
            exit 1
        fi
        echo "${actual}  ${name}" >> "${LOCKFILE}"
        echo "    pinned:   ${name} (cross-checked against ${source_label}) — commit artifacts.sha256"
    else
        echo "${actual}  ${name}" >> "${LOCKFILE}"
        echo "    pinned:   ${name} (trust-on-first-use, no independent source) — commit artifacts.sha256"
        echo "              verify manually if required: sha256 = ${actual}"
    fi
}

# Downloads a fatpack binary (cpanm, cpm) under a version-suffixed filename,
# with a stable symlink pointing at it — see the comment at the call site
# below for why this matters more here than for the other artifact types.
fetch_versioned_binary() {
    local url="$1" name="$2" version="$3"
    local versioned="${ARTIFACTS_DIR}/${name}-${version}"
    download "${url}" "${versioned}"
    verify_or_learn "${versioned}"
    chmod +x "${versioned}"
    ln -sfn "${name}-${version}" "${ARTIFACTS_DIR}/${name}"
}

# --- Main ----------------------------------------------------------------------

mkdir -p "${ARTIFACTS_DIR}"
touch "${LOCKFILE}"

# Perl source tarball — has an independent checksum source (MetaCPAN), used
# only when the artifact is not yet pinned.
PERL_TARBALL="${ARTIFACTS_DIR}/perl-${PERL_VERSION}.tar.gz"
download "${PERL_URL}" "${PERL_TARBALL}"
if [ -z "$(lockfile_hash_for "perl-${PERL_VERSION}.tar.gz")" ]; then
    echo "==> Looking up published sha256 for perl-${PERL_VERSION} on MetaCPAN..."
    PUBLISHED_SHA="$(metacpan_perl_sha256 "${PERL_VERSION}" || true)"
    SHA_SOURCE="MetaCPAN"
    if [ -z "${PUBLISHED_SHA}" ]; then
        echo "==> MetaCPAN lookup failed; falling back to CPAN CHECKSUMS index..."
        PUBLISHED_SHA="$(cpan_checksums_sha256 "perl-${PERL_VERSION}.tar.gz" || true)"
        SHA_SOURCE="CPAN CHECKSUMS (PGP-signed index, signature not verified)"
    fi
    if [ -z "${PUBLISHED_SHA}" ]; then
        echo "ERROR: could not obtain sha256 for perl-${PERL_VERSION}.tar.gz from any source." >&2
        echo "(Tried MetaCPAN and the CPAN CHECKSUMS index — see messages above.)" >&2
        echo "Refusing to pin without an independent check. Verify manually, e.g.:" >&2
        echo "    curl -fsSL https://www.cpan.org/src/5.0/CHECKSUMS | grep -A8 \"'perl-${PERL_VERSION}.tar.gz'\"" >&2
        echo "then pin it yourself:" >&2
        echo "    echo '<sha256>  perl-${PERL_VERSION}.tar.gz' >> artifacts.sha256" >&2
        exit 1
    fi
    verify_or_learn "${PERL_TARBALL}" "${PUBLISHED_SHA}" "${SHA_SOURCE}"
else
    verify_or_learn "${PERL_TARBALL}"
fi

# cpanm / cpm — fetched from immutable release tags; TOFU-pinned.
#
# fetch_versioned_binary downloads under a version-suffixed filename with a
# stable symlink pointing at it — same pattern as bundle-latest.tar.gz
# elsewhere in this repo. This matters more here than for the Perl tarball or
# Oracle zips: those filenames already encode their version, but a bare
# `artifacts/cpanm` would never change name across a CPANM_VERSION bump, and
# download() skips fetching whenever the destination already exists — so
# bumping the version constant would silently keep running the old cached
# binary forever without the version suffix.
fetch_versioned_binary "${CPANM_URL}" cpanm "${CPANM_VERSION}"
fetch_versioned_binary "${CPM_URL}" cpm "${CPM_VERSION}"

# Oracle Instant Client — versioned URLs; TOFU-pinned. Hashes can be manually
# cross-checked once against the checksums published on Oracle's download page.
download "${ORACLE_BASE_URL}/${ORACLE_BASICLITE_ZIP}" "${ARTIFACTS_DIR}/${ORACLE_BASICLITE_ZIP}"
verify_or_learn "${ARTIFACTS_DIR}/${ORACLE_BASICLITE_ZIP}"

download "${ORACLE_BASE_URL}/${ORACLE_SDK_ZIP}" "${ARTIFACTS_DIR}/${ORACLE_SDK_ZIP}"
verify_or_learn "${ARTIFACTS_DIR}/${ORACLE_SDK_ZIP}"

echo ""
echo "==> Done. Artifacts in ${ARTIFACTS_DIR}:"
ls -la "${ARTIFACTS_DIR}"

if [ "${MIRROR_MODE}" -eq 1 ]; then
    echo ""
    echo "==> Mirroring artifacts into Nexus (${NEXUS_BASE_URL}/)..."
    for f in "${PERL_TARBALL}" \
        "${ARTIFACTS_DIR}/cpanm-${CPANM_VERSION}" \
        "${ARTIFACTS_DIR}/cpm-${CPM_VERSION}" \
        "${ARTIFACTS_DIR}/${ORACLE_BASICLITE_ZIP}" \
        "${ARTIFACTS_DIR}/${ORACLE_SDK_ZIP}"; do
        name="$(basename "${f}")"
        echo "    uploading ${name}..."
        curl -fsSL -u "${NEXUS_USER}:${NEXUS_PASSWORD}" --upload-file "${f}" "${NEXUS_BASE_URL}/${name}"
    done
    echo "==> Mirror upload complete."
fi
