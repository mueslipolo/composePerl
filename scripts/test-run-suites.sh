#!/usr/bin/env bash
set -euo pipefail

# test-run-suites.sh - Full CPAN test suite runner
#
# Purpose: Runs complete test suites for all modules (slow but thorough)
# Usage:   test-run-suites.sh [module-name]
#          Or via: make test-full, make test-full MODULE=name
#          Optional: specify module name to test only that module
# Config:  Uses tests/test-config.conf (skip_test, env.*, test_command)
# Output:  Summary and detailed reports saved to test-reports/ directory
# Note:    Only runs on dev image (runtime lacks build tools for testing)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORTS_DIR="${PROJECT_ROOT}/test-reports"
CONFIG_FILE="${PROJECT_ROOT}/tests/test-config.conf"
IMAGE_NAME="myapp:dev"

# Module name is now first argument
MODULE_NAME="${1:-}"

if [[ -n "${MODULE_NAME}" ]]; then
    echo "==> Running test suite for ${MODULE_NAME} in ${IMAGE_NAME}"
else
    echo "==> Running full CPAN test suites in ${IMAGE_NAME}"
    echo "    This will take a while as it runs all module tests..."
fi
echo ""

# Check if image exists
if ! podman image exists "${IMAGE_NAME}"; then
    echo "ERROR: Image ${IMAGE_NAME} does not exist"
    echo "Build the image first with: make dev"
    exit 1
fi

# Create reports directory
mkdir -p "${REPORTS_DIR}"

# Generate timestamp and report paths
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
if [[ -n "${MODULE_NAME}" ]]; then
    # Sanitize module name for filename (replace :: with -)
    MODULE_SAFE=$(echo "${MODULE_NAME}" | tr ':' '-')
    REPORT_SUMMARY="${REPORTS_DIR}/${MODULE_SAFE}-${TIMESTAMP}-summary.txt"
    REPORT_DETAIL_DIR="${REPORTS_DIR}/${MODULE_SAFE}-${TIMESTAMP}-details"
else
    REPORT_SUMMARY="${REPORTS_DIR}/full-${TIMESTAMP}-summary.txt"
    REPORT_DETAIL_DIR="${REPORTS_DIR}/full-${TIMESTAMP}-details"
fi

echo "==> Reports will be saved to:"
echo "    Summary: ${REPORT_SUMMARY}"
echo "    Details: ${REPORT_DETAIL_DIR}/"
echo ""

# Create container and run test suite
if [[ -n "${MODULE_NAME}" ]]; then
    CONTAINER_ID=$(podman create \
        -v "${PROJECT_ROOT}/cpanfile:/tmp/cpanfile:ro" \
        -v "${CONFIG_FILE}:/tmp/test-config.conf:ro" \
        -v "${PROJECT_ROOT}/tests/test-suite-runner.pl:/tmp/test-suite-runner.pl:ro" \
        -v "${PROJECT_ROOT}/tests/TestConfig.pm:/tmp/TestConfig.pm:ro" \
        "${IMAGE_NAME}" \
        /opt/perl/bin/perl /tmp/test-suite-runner.pl "${MODULE_NAME}")
else
    CONTAINER_ID=$(podman create \
        -v "${PROJECT_ROOT}/cpanfile:/tmp/cpanfile:ro" \
        -v "${CONFIG_FILE}:/tmp/test-config.conf:ro" \
        -v "${PROJECT_ROOT}/tests/test-suite-runner.pl:/tmp/test-suite-runner.pl:ro" \
        -v "${PROJECT_ROOT}/tests/TestConfig.pm:/tmp/TestConfig.pm:ro" \
        "${IMAGE_NAME}" \
        /opt/perl/bin/perl /tmp/test-suite-runner.pl)
fi

# Start container and capture output
# Don't let pipefail stop us from extracting the detail log
set +e
podman start -a "${CONTAINER_ID}" | tee "${REPORT_SUMMARY}"
TEST_EXIT_CODE=${PIPESTATUS[0]}
set -e

# Extract detailed logs directory from container
echo ""
echo "==> Extracting detailed logs..."
mkdir -p "${REPORT_DETAIL_DIR}"
podman cp "${CONTAINER_ID}:/tmp/test-details/." "${REPORT_DETAIL_DIR}/" 2>/dev/null || {
    if [[ -n "${MODULE_NAME}" ]]; then
        echo "WARNING: No detailed logs to extract"
    else
        echo "WARNING: No detailed logs to extract (all tests may have passed)"
    fi
}

# Cleanup container
podman rm "${CONTAINER_ID}" > /dev/null

echo ""
echo "==> Reports saved:"
echo "    Summary: ${REPORT_SUMMARY}"

# Count detail files
DETAIL_COUNT=$(find "${REPORT_DETAIL_DIR}" -name "*.log" 2>/dev/null | wc -l)
if [[ ${DETAIL_COUNT} -gt 0 ]]; then
    if [[ -n "${MODULE_NAME}" ]]; then
        echo "    Details: ${REPORT_DETAIL_DIR}/ (${DETAIL_COUNT} log file(s))"
    else
        echo "    Details: ${REPORT_DETAIL_DIR}/ (${DETAIL_COUNT} failed module(s))"
    fi
else
    echo "    Details: ${REPORT_DETAIL_DIR}/ (no logs generated)"
fi

echo ""

if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
    echo "==> All tests PASSED for ${IMAGE_NAME}"
    exit 0
else
    echo "==> Some tests FAILED for ${IMAGE_NAME}"
    echo "    Check details: ${REPORT_DETAIL_DIR}/"
    exit 1
fi
