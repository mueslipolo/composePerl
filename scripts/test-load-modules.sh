#!/usr/bin/env bash
set -euo pipefail

# test-load-modules.sh - Quick module smoke test runner
#
# Purpose: Verifies all modules in cpanfile can be loaded (quick smoke test)
# Usage:   test-load-modules.sh [dev|runtime]
#          Or via: make test-load-dev, make test-load-runtime
# Config:  Uses tests/test-config.conf (skip_load setting)
# Output:  Pass/Fail count and list of skipped modules
# Note:    Full test suites (make test-full) only work on dev image

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Determine which image to test
TEST_TARGET="${1:-dev}"

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
echo "==> Running module-load-test.pl in container..."
echo ""

podman run --rm \
    -v "${PROJECT_ROOT}/tests/module-load-test.pl:/tmp/module-load-test.pl:ro" \
    -v "${PROJECT_ROOT}/tests/TestConfig.pm:/tmp/TestConfig.pm:ro" \
    -v "${PROJECT_ROOT}/cpanfile:/tmp/cpanfile:ro" \
    -v "${PROJECT_ROOT}/tests/test-config.conf:/tmp/test-config.conf:ro" \
    "${IMAGE_NAME}" \
    /opt/perl/bin/perl /tmp/module-load-test.pl

TEST_EXIT_CODE=$?

echo ""
if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
    echo "==> Tests passed for ${IMAGE_NAME}"
else
    echo "==> Tests FAILED for ${IMAGE_NAME}"
    exit ${TEST_EXIT_CODE}
fi
