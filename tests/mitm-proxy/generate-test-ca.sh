#!/usr/bin/env bash
set -euo pipefail

# generate-test-ca.sh - Generate a throwaway CA + leaf cert for mitm_proxy.py
#
# Purpose: Creates a self-signed test CA and a leaf certificate (signed by
#          that CA) covering the given hostnames, for mitm_proxy.py's TLS
#          interception. Never commit the output — it's regenerated fresh
#          for each CI run / local test.
# Usage:   generate-test-ca.sh <output-dir> <hostname> [hostname...]
# Output:  <output-dir>/test-ca.pem   - the CA cert to install as VM_CA_CERT
#                                       / CURL_CA_BUNDLE / certs/ trust anchor
#          <output-dir>/leaf.pem      - leaf cert (signed by the CA)
#          <output-dir>/leaf.key      - leaf private key

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <output-dir> <hostname> [hostname...]" >&2
    exit 2
fi

OUT_DIR="$1"
shift
HOSTNAMES=("$@")

mkdir -p "${OUT_DIR}"

# 1. Throwaway CA (key + self-signed cert).
openssl genrsa -out "${OUT_DIR}/test-ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "${OUT_DIR}/test-ca.key" -sha256 -days 1 \
    -subj "/CN=composePerl Test CA" -out "${OUT_DIR}/test-ca.pem" 2>/dev/null

# 2. Leaf key + CSR, with a SAN entry per requested hostname.
openssl genrsa -out "${OUT_DIR}/leaf.key" 2048 2>/dev/null
SAN=$(printf 'DNS:%s,' "${HOSTNAMES[@]}")
SAN="${SAN%,}"
echo "subjectAltName=${SAN}" > "${OUT_DIR}/leaf.ext"
openssl req -new -key "${OUT_DIR}/leaf.key" -subj "/CN=mitm-test-leaf" \
    -out "${OUT_DIR}/leaf.csr" 2>/dev/null

# 3. Sign the leaf with the test CA, including the SAN extension.
openssl x509 -req -in "${OUT_DIR}/leaf.csr" \
    -CA "${OUT_DIR}/test-ca.pem" -CAkey "${OUT_DIR}/test-ca.key" -CAcreateserial \
    -out "${OUT_DIR}/leaf.pem" -days 1 -sha256 -extfile "${OUT_DIR}/leaf.ext" 2>/dev/null

rm -f "${OUT_DIR}/leaf.csr" "${OUT_DIR}/test-ca.srl"

echo "==> Test CA + leaf cert generated in ${OUT_DIR}"
echo "    SANs: ${SAN}"
