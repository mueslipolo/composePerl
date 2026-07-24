#!/usr/bin/env bash
set -euo pipefail

# security-audit.sh - check pinned CPAN/Perl-core modules AND OS packages
#                      for known CVEs
#
# Purpose: Combines two scanners into one report:
#            - cpan-audit (CPAN::Audit) against cpanfile.snapshot for
#              CPAN/Perl-core advisories — fails on ANY match, since most
#              CPANSA advisories don't carry a severity.
#            - trivy against the built runtime image for OS-package
#              advisories — fails only on HIGH/CRITICAL, since OS severity
#              data is reliable and RPM-set advisory volume is much higher.
#          See docs/security-audit.md for the full reasoning.
# Usage:   scripts/security-audit.sh [output-path]
#          Or via: make security-audit
# Needs:   cpan-audit on PATH (cpanm --notest CPAN::Audit); jq. Mandatory —
#          the script hard-fails without these.
#          trivy on PATH + a built ${IMAGE_NAME:-myapp}:runtime image are
#          optional locally: if either is missing, the OS-package section
#          is skipped with a note rather than failing the script. Both are
#          installed/built by CI, so the OS half always runs there.
# Output:  <output-path> (JSON, default security-audit.json) and a sibling
#          <output-path minus .json>.md human-readable report, always
#          written to disk (not just stdout/$GITHUB_STEP_SUMMARY).
# Exit:    non-zero if either half found something.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-myapp}"
TRIVY_SEVERITY="HIGH,CRITICAL"

OUTPUT="${1:-${PROJECT_ROOT}/security-audit.json}"
REPORT_OUTPUT="${OUTPUT%.json}.md"
CPANFILE_SNAPSHOT="${PROJECT_ROOT}/cpanfile.snapshot"
RUNTIME_IMAGE="${IMAGE_NAME}:runtime"

echo "==> Checking preconditions..."

if ! command -v cpan-audit >/dev/null 2>&1; then
    echo "ERROR: cpan-audit not found on PATH." >&2
    echo "       Run: cpanm --notest CPAN::Audit" >&2
    exit 1
fi

if [[ ! -f "${CPANFILE_SNAPSHOT}" ]]; then
    echo "ERROR: cpanfile.snapshot not found at ${CPANFILE_SNAPSHOT}" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required (used to render the advisory report)." >&2
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "==> CPAN/Perl-core half: cpan-audit against ${CPANFILE_SNAPSHOT}..."
set +e
cpan-audit deps "${PROJECT_ROOT}" --perl --json > "${WORKDIR}/cpan-audit.json"
CPAN_STATUS=$?
set -e

OS_SKIPPED=""
if ! command -v trivy >/dev/null 2>&1; then
    OS_SKIPPED="trivy not installed (see docs/security-audit.md)"
elif ! command -v podman >/dev/null 2>&1; then
    OS_SKIPPED="podman not installed (needed to save ${RUNTIME_IMAGE} for scanning)"
elif ! podman image exists "${RUNTIME_IMAGE}" 2>/dev/null; then
    OS_SKIPPED="${RUNTIME_IMAGE} not found — run 'make runtime' first for OS-package coverage"
fi

OS_STATUS=0
if [[ -n "${OS_SKIPPED}" ]]; then
    echo "==> OS-package half: skipped (${OS_SKIPPED})"
else
    echo "==> OS-package half: trivy against ${RUNTIME_IMAGE}..."
    podman save "${RUNTIME_IMAGE}" -o "${WORKDIR}/image.tar"
    set +e
    trivy image --input "${WORKDIR}/image.tar" --severity "${TRIVY_SEVERITY}" \
        --exit-code 1 --format json --output "${WORKDIR}/trivy.json"
    OS_STATUS=$?
    set -e
fi

echo "==> Combining results..."
if [[ ! -f "${WORKDIR}/trivy.json" ]]; then
    echo null > "${WORKDIR}/trivy.json"
fi
jq -n --slurpfile cpan "${WORKDIR}/cpan-audit.json" --slurpfile os "${WORKDIR}/trivy.json" \
    '{cpan: $cpan[0], os: $os[0]}' > "${OUTPUT}"

cpan_report() {
    jq -r '
      .cpan.meta.total_advisories as $total |
      if $total == 0 then
        "No known CVE advisories against pinned CPAN/Perl-core modules."
      else
        "\($total) advisory(ies) found against pinned CPAN/Perl-core modules:",
        (
          .cpan.dists | to_entries | sort_by(.key)[] |
          .key as $dist | .value.version as $ver |
          .value.advisories[] |
          "  - \($dist) \($ver): \(.id)"
          + (if (.cves // []) | length > 0 then " (\(.cves | join(", ")))" else "" end)
          + (if (.fixed_versions // []) | length > 0 then " — fix: \(.fixed_versions | join(", "))" else " — no fix published" end)
        )
      end
    ' "${OUTPUT}"
}

os_report() {
    if [[ -n "${OS_SKIPPED}" ]]; then
        echo "Skipped: ${OS_SKIPPED}"
        return
    fi
    jq -r '
      [.os.Results[]? | .Vulnerabilities[]? ] as $vulns |
      if ($vulns | length) == 0 then
        "No HIGH/CRITICAL OS-package advisories found."
      else
        ($vulns | length | tostring) + " HIGH/CRITICAL OS-package advisory(ies) found:",
        (
          $vulns[] |
          "  - \(.PkgName) \(.InstalledVersion): \(.VulnerabilityID) (\(.Severity))"
          + (if .FixedVersion then " — fix: \(.FixedVersion)" else " — no fix published" end)
        )
      end
    ' "${OUTPUT}"
}

{
    echo "# Perl/CPAN + OS-package security audit"
    echo
    echo "## CPAN / Perl-core (cpan-audit)"
    echo
    cpan_report
    echo
    echo "## OS packages (trivy, HIGH/CRITICAL only)"
    echo
    os_report
} > "${REPORT_OUTPUT}"

cat "${REPORT_OUTPUT}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "${REPORT_OUTPUT}" >> "${GITHUB_STEP_SUMMARY}"
fi

echo "==> Report written to ${REPORT_OUTPUT}"

if [[ "${CPAN_STATUS}" -ne 0 || "${OS_STATUS}" -ne 0 ]]; then
    exit 1
fi
exit 0
