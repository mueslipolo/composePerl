#!/usr/bin/env bash
set -Eeuo pipefail

# vm-bootstrap-perlbrew.sh - Install perlbrew + a pinned Perl version onto a VM
#
# Purpose: Makes docs/vm-deployment.md's "Prerequisites on the VM" section
#          real and testable: installs perlbrew itself (if not already
#          present) and the Perl version a bundle was resolved against,
#          behind an enterprise proxy / custom CA if the VM needs one.
# Usage:   vm-bootstrap-perlbrew.sh <perl-version> [local-perl-tarball]
# Env:     PERLBREW_ROOT           - install location, default $HOME/perl5/perlbrew
#          VM_CA_CERT              - optional path to a corporate CA cert to trust
#          VM_CA_TRUST_ANCHORS_DIR - where to install it, default
#                                    /etc/pki/ca-trust/source/anchors (RHEL-family)
#          http_proxy/https_proxy/no_proxy (or uppercase) - see docs/proxy.md

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <perl-version> [local-perl-tarball]" >&2
    exit 2
fi

PERL_VERSION="$1"
LOCAL_TARBALL="${2:-}"
# perlbrew changes its own working directory internally before extracting a
# local-tarball install argument, so a relative path silently stops
# resolving partway through — resolve to an absolute path up front instead
# (verified against the real failure: "tar (child): ./perl-X.tar.gz: Cannot
# open: No such file or directory" when passed relative).
if [[ -n "${LOCAL_TARBALL}" ]]; then
    LOCAL_TARBALL="$(cd "$(dirname "${LOCAL_TARBALL}")" && pwd)/$(basename "${LOCAL_TARBALL}")"
fi
PERLBREW_ROOT="${PERLBREW_ROOT:-$HOME/perl5/perlbrew}"
VM_CA_TRUST_ANCHORS_DIR="${VM_CA_TRUST_ANCHORS_DIR:-/etc/pki/ca-trust/source/anchors}"

# Fold uppercase HTTP_PROXY/HTTPS_PROXY/NO_PROXY in as a fallback — some
# corporate environments only export that form, but curl (perlbrew's
# installer, and perlbrew's own Perl-source fetch) reads lowercase. See
# docs/proxy.md.
: "${http_proxy:=${HTTP_PROXY:-}}"
: "${https_proxy:=${HTTPS_PROXY:-}}"
: "${no_proxy:=${NO_PROXY:-}}"
export http_proxy https_proxy no_proxy

if [[ -n "${https_proxy}" || -n "${http_proxy}" ]]; then
    echo "==> Proxy: http_proxy=${http_proxy:-<unset>} https_proxy=${https_proxy:-<unset>} no_proxy=${no_proxy:-<unset>}"
else
    echo "==> No proxy configured"
fi

# Prints a targeted hint if the failure that just aborted the script (under
# set -e) looks network/TLS-related, so a raw curl/perlbrew error doesn't
# require re-deriving "is this a proxy problem?" by hand. Silent for
# anything else (e.g. a missing VM_CA_CERT file) — it can't misdirect if it
# only speaks up for the failures it actually recognizes. perlbrew wraps its
# own internal fetches (patchperl, Perl source) in its own exit codes, not
# curl's raw ones (confirmed: a failed patchperl fetch exits 4) — so this
# also matches on the failing command mentioning curl/perlbrew, not just the
# exit code.
_diagnose_network_failure() {
    local exit_code="$1" failing_cmd="$2"
    case "${exit_code}" in
        6|7|28|35|51|52|55|56|58|60|77|82|83) ;;  # curl network/TLS exit codes
        *) [[ "${failing_cmd}" == *curl* || "${failing_cmd}" == *perlbrew* ]] || return 0 ;;
    esac
    echo "" >&2
    echo "==> Network/TLS error (exit ${exit_code}) while running: ${failing_cmd}" >&2
    echo "    If you're behind a corporate proxy, check:" >&2
    echo "      - http_proxy / https_proxy / no_proxy are set and correct" >&2
    echo "      - your CA trust store (VM_CA_CERT) trusts the proxy" >&2
    echo "    See docs/proxy.md for details." >&2
}
trap '_diagnose_network_failure $? "$BASH_COMMAND"' ERR

# Optional custom CA for a TLS-inspecting corporate proxy — the VM-side
# equivalent of the Containerfile's certs/ mechanism (see docs/proxy.md).
# Assumes a RHEL-family trust store, matching this fleet's UBI/RHEL baseline.
if [[ -n "${VM_CA_CERT:-}" ]]; then
    if [[ ! -f "${VM_CA_CERT}" ]]; then
        echo "ERROR: VM_CA_CERT=${VM_CA_CERT} does not exist" >&2
        exit 1
    fi
    echo "==> Installing custom CA cert: ${VM_CA_CERT}"
    cp "${VM_CA_CERT}" "${VM_CA_TRUST_ANCHORS_DIR}/"
    update-ca-trust extract
else
    echo "==> No custom CA configured (VM_CA_CERT unset)"
fi

# Install perlbrew itself, if not already present.
if [[ -x "${PERLBREW_ROOT}/bin/perlbrew" ]]; then
    echo "==> perlbrew already installed at ${PERLBREW_ROOT}"
else
    echo "==> Installing perlbrew into ${PERLBREW_ROOT}..."
    curl -L https://install.perlbrew.pl | bash
fi

export PATH="${PERLBREW_ROOT}/bin:${PATH}"

# Install the pinned Perl version, if not already present. perlbrew always
# names a standard install "perl-<version>" internally regardless of what
# form you pass it — see the version-compatibility gate, which checks for
# exactly that prefix.
if perlbrew list | grep -qF "perl-${PERL_VERSION}"; then
    echo "==> perl-${PERL_VERSION} already installed"
elif [[ -n "${LOCAL_TARBALL}" ]]; then
    echo "==> Installing perl-${PERL_VERSION} from local tarball ${LOCAL_TARBALL} (offline, no network needed for the compile)..."
    perlbrew --notest install "${LOCAL_TARBALL}"
else
    echo "==> Installing perl-${PERL_VERSION} from network..."
    perlbrew --notest install "${PERL_VERSION}"
fi

echo "==> Done: perl-${PERL_VERSION} available under ${PERLBREW_ROOT}"
