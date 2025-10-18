#!/usr/bin/env bash
set -euo pipefail

# check-status.sh
# Checks the status of bundles and images relative to cpanfile.snapshot

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLES_DIR="${PROJECT_ROOT}/bundles"
CPANFILE_SNAPSHOT="${PROJECT_ROOT}/cpanfile.snapshot"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track if anything needs updating
NEEDS_UPDATE=false

echo "==> Dependency Status Check"
echo ""

# ============================================================================
# Check cpanfile.snapshot
# ============================================================================

if [[ ! -f "${CPANFILE_SNAPSHOT}" ]]; then
    echo -e "${RED}✗${NC} cpanfile.snapshot not found"
    exit 1
fi

SNAPSHOT_HASH=$(sha256sum "${CPANFILE_SNAPSHOT}" | cut -c1-12)
echo -e "${BLUE}Snapshot hash:${NC} ${SNAPSHOT_HASH}"

# Check if snapshot has uncommitted changes (if in git repo)
if git rev-parse --git-dir > /dev/null 2>&1; then
    if git diff --quiet "${CPANFILE_SNAPSHOT}" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} No uncommitted changes"
    else
        echo -e "  ${YELLOW}⚠${NC} Uncommitted changes detected"
    fi
fi

echo ""

# ============================================================================
# Check bundle status
# ============================================================================

BUNDLE_NAME="bundle-${SNAPSHOT_HASH}.tar.gz"
BUNDLE_PATH="${BUNDLES_DIR}/${BUNDLE_NAME}"
BUNDLE_LATEST="${BUNDLES_DIR}/bundle-latest.tar.gz"

echo -e "${BLUE}Bundle status:${NC}"

if [[ -f "${BUNDLE_PATH}" ]]; then
    BUNDLE_SIZE=$(du -h "${BUNDLE_PATH}" | cut -f1)
    echo -e "  ${GREEN}✓${NC} Bundle exists: ${BUNDLE_NAME} (${BUNDLE_SIZE})"

    # Check if symlink points to correct bundle
    if [[ -L "${BUNDLE_LATEST}" ]]; then
        CURRENT_LATEST=$(readlink "${BUNDLE_LATEST}")
        if [[ "${CURRENT_LATEST}" == "${BUNDLE_NAME}" ]]; then
            echo -e "  ${GREEN}✓${NC} Symlink up to date: bundle-latest.tar.gz -> ${BUNDLE_NAME}"
        else
            echo -e "  ${YELLOW}⚠${NC} Symlink outdated: points to ${CURRENT_LATEST}"
            NEEDS_UPDATE=true
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} Symlink missing"
        NEEDS_UPDATE=true
    fi
else
    echo -e "  ${RED}✗${NC} Bundle missing: ${BUNDLE_NAME}"
    echo -e "  ${YELLOW}→${NC} Run: ${GREEN}make bundle${NC}"
    NEEDS_UPDATE=true
fi

echo ""

# ============================================================================
# Check image status
# ============================================================================

echo -e "${BLUE}Image status:${NC}"

# Helper function to check if image exists and get its labels
check_image() {
    local image_name=$1
    local image_tag=$2
    local full_name="${image_name}:${image_tag}"

    if podman image exists "${full_name}" 2>/dev/null; then
        # Try to get the bundle hash from image labels
        local image_hash=$(podman inspect "${full_name}" --format '{{index .Config.Labels "bundle.hash"}}' 2>/dev/null || echo "")

        if [[ -n "${image_hash}" && "${image_hash}" == "${SNAPSHOT_HASH}" ]]; then
            echo -e "  ${GREEN}✓${NC} ${full_name} (bundle: ${image_hash})"
            return 0
        elif [[ -n "${image_hash}" ]]; then
            echo -e "  ${YELLOW}⚠${NC} ${full_name} (bundle: ${image_hash}, expected: ${SNAPSHOT_HASH})"
            return 1
        else
            echo -e "  ${YELLOW}⚠${NC} ${full_name} (no bundle hash label)"
            return 1
        fi
    else
        echo -e "  ${RED}✗${NC} ${full_name} not found"
        return 2
    fi
}

# Check carton-runner (may not exist, that's ok)
if podman image exists "myapp:carton-runner" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} myapp:carton-runner exists"
fi

# Check dev image
if ! check_image "myapp" "dev"; then
    echo -e "  ${YELLOW}→${NC} Run: ${GREEN}make dev${NC}"
    NEEDS_UPDATE=true
fi

# Check runtime image
if ! check_image "myapp" "runtime"; then
    echo -e "  ${YELLOW}→${NC} Run: ${GREEN}make runtime${NC}"
    NEEDS_UPDATE=true
fi

echo ""

# ============================================================================
# Summary
# ============================================================================

if [[ "${NEEDS_UPDATE}" == "false" ]]; then
    echo -e "${GREEN}✓ Everything up to date!${NC}"
else
    echo -e "${YELLOW}⚠ Updates needed${NC}"
    echo ""
    echo "Recommended workflow:"

    if [[ ! -f "${BUNDLE_PATH}" ]]; then
        echo "  1. ${GREEN}make bundle${NC}  # Generate bundle"
        echo "  2. ${GREEN}make dev${NC}     # Build dev image"
        echo "  3. ${GREEN}make runtime${NC} # Build runtime image"
    else
        echo "  1. ${GREEN}make dev${NC}     # Build dev image"
        echo "  2. ${GREEN}make runtime${NC} # Build runtime image"
    fi

    echo ""
    echo "Or run: ${GREEN}make all${NC}"
fi

echo ""

# Exit with appropriate code
if [[ "${NEEDS_UPDATE}" == "true" ]]; then
    exit 1
else
    exit 0
fi
