#!/usr/bin/env bash
set -euo pipefail

# test-image.sh
# Tests Perl library loading in built Docker images
#
# Usage:
#   test-image.sh [dev|runtime]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Determine which image to test
TEST_TARGET="${1:-}"

if [[ -z "${TEST_TARGET}" ]]; then
    echo "ERROR: No target specified"
    echo "Usage: $0 [dev|runtime]"
    exit 1
fi

case "${TEST_TARGET}" in
    dev)
        IMAGE_NAME="myapp:dev"
        ;;
    runtime)
        IMAGE_NAME="myapp:runtime"
        ;;
    *)
        echo "ERROR: Invalid target '${TEST_TARGET}'"
        echo "Usage: $0 [dev|runtime]"
        exit 1
        ;;
esac

echo "==> Testing Perl libraries in ${IMAGE_NAME}"

# Check if image exists
if ! podman image exists "${IMAGE_NAME}"; then
    echo "ERROR: Image ${IMAGE_NAME} does not exist"
    echo "Build the image first with: make ${TEST_TARGET}"
    exit 1
fi

# Run the test script inside the container
echo "==> Running perl-lib-test.pl in container..."
echo ""

podman run --rm \
    -v "${PROJECT_ROOT}/scripts/perl-lib-test.pl:/tmp/perl-lib-test.pl:ro" \
    -v "${PROJECT_ROOT}/cpanfile:/tmp/cpanfile:ro" \
    "${IMAGE_NAME}" \
    /opt/perl/bin/perl /tmp/perl-lib-test.pl

TEST_EXIT_CODE=$?

echo ""
if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
    echo "==> Tests passed for ${IMAGE_NAME}"
else
    echo "==> Tests FAILED for ${IMAGE_NAME}"
    exit ${TEST_EXIT_CODE}
fi
