#!/usr/bin/env bash
set -euo pipefail

# vm-check-compat.sh - Version-compatibility gate for a VM bundle install
#
# Purpose: Makes docs/vm-deployment.md's "Version-compatibility gate" real:
#          fails loudly, before any install happens, if the bundle's pinned
#          Perl version isn't installed under perlbrew, or if the bundle was
#          resolved against a different RHEL major than this VM runs. XS
#          modules are ABI-bound to both, not just the Perl version.
# Usage:   vm-check-compat.sh <bundle-info-file>
# Env:     PERLBREW_ROOT - default $HOME/perl5/perlbrew

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <bundle-info-file>" >&2
    exit 2
fi

BUILD_INFO="$1"
PERLBREW_ROOT="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}"

if [[ ! -f "${BUILD_INFO}" ]]; then
    echo "ERROR: build-info file not found: ${BUILD_INFO}" >&2
    exit 1
fi

# PERL_VERSION and UBI_IMAGE come from the bundle's own stamp, not a value
# copied in by hand.
# shellcheck source=/dev/null
source "${BUILD_INFO}"

if [[ -z "${PERL_VERSION:-}" ]]; then
    echo "ERROR: ${BUILD_INFO} did not set PERL_VERSION" >&2
    exit 1
fi

export PATH="${PERLBREW_ROOT}/bin:${PATH}"

if ! perlbrew list | grep -qF "perl-${PERL_VERSION}"; then
    echo "FAIL: perlbrew has no perl-${PERL_VERSION}; this bundle needs it" >&2
    exit 1
fi
echo "OK: perlbrew has perl-${PERL_VERSION}"

# UBI_IMAGE records the *container* OS the bundle's compiled-module
# resolution assumed. Map its RHEL major version to this VM's, when the VM
# exposes one (RPM-based hosts do via the %{rhel} macro) — skip the check
# on non-RPM hosts rather than fail on a check that can't be made.
if [[ -n "${UBI_IMAGE:-}" ]]; then
    bundle_rhel_major=$(echo "${UBI_IMAGE}" | grep -oE 'ubi[0-9]+' | grep -oE '[0-9]+' || true)
    if [[ -z "${bundle_rhel_major}" ]]; then
        echo "WARNING: could not parse a RHEL major version out of UBI_IMAGE=${UBI_IMAGE}; skipping OS check" >&2
    elif command -v rpm >/dev/null 2>&1; then
        vm_rhel_major=$(rpm -E '%{rhel}' 2>/dev/null || true)
        if [[ -z "${vm_rhel_major}" || "${vm_rhel_major}" == '%{rhel}' ]]; then
            echo "WARNING: 'rpm -E %{rhel}' did not return a version; skipping OS check" >&2
        elif [[ "${vm_rhel_major}" != "${bundle_rhel_major}" ]]; then
            echo "FAIL: bundle resolved against RHEL ${bundle_rhel_major} (${UBI_IMAGE}), this VM is RHEL ${vm_rhel_major}" >&2
            exit 1
        else
            echo "OK: bundle RHEL major (${bundle_rhel_major}) matches this VM (${vm_rhel_major})"
        fi
    else
        echo "WARNING: no 'rpm' command found; skipping OS check" >&2
    fi
fi

echo "OK: compatibility gate passed"
