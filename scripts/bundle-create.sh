#!/usr/bin/env bash
set -euo pipefail

# bundle-create.sh - CPAN bundle and dependency manager
#
# Purpose: Manages Perl dependencies using Carton
# Usage:   bundle-create.sh bundle - Generate CPAN bundle from cpanfile.snapshot
#          bundle-create.sh update --all - Update all dependencies to latest
#          bundle-create.sh update --module MODULE - Update specific module to latest
#          Or via: make bundle
# Output:  Creates bundles/bundle-{HASH}.tar.gz with CPAN mirror
# Note:    To pin to a specific version, edit cpanfile manually (e.g., requires 'DBI', '== 1.643';)

# ============================================================================
# Setup and shared functions
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLES_DIR="${PROJECT_ROOT}/bundles"
CPANFILE="${PROJECT_ROOT}/cpanfile"
CPANFILE_SNAPSHOT="${PROJECT_ROOT}/cpanfile.snapshot"
CONTAINERFILE="${PROJECT_ROOT}/Containerfile"

setup_paths() {
    mkdir -p "${BUNDLES_DIR}"
}

build_carton_runner() {
    echo "==> Building carton-runner stage..."
    podman build \
        --target carton-runner \
        -t myapp:carton-runner \
        -f "${CONTAINERFILE}" \
        "${PROJECT_ROOT}"
}

# ============================================================================
# Bundle command - Generate CPAN bundle artifact
# ============================================================================

cmd_bundle() {
    echo "==> Managing Perl dependencies bundle"

    setup_paths

    # Verify cpanfile.snapshot exists
    if [[ ! -f "${CPANFILE_SNAPSHOT}" ]]; then
        echo "ERROR: cpanfile.snapshot not found at ${CPANFILE_SNAPSHOT}"
        exit 1
    fi

    # Compute SHA256 hash of cpanfile.snapshot (first 12 characters)
    SNAPSHOT_HASH=$(sha256sum "${CPANFILE_SNAPSHOT}" | cut -c1-12)
    echo "==> Snapshot hash: ${SNAPSHOT_HASH}"

    BUNDLE_NAME="bundle-${SNAPSHOT_HASH}.tar.gz"
    BUNDLE_PATH="${BUNDLES_DIR}/${BUNDLE_NAME}"
    BUNDLE_LATEST="${BUNDLES_DIR}/bundle-latest.tar.gz"

    # Check if bundle already exists
    if [[ -f "${BUNDLE_PATH}" ]]; then
        echo "==> Bundle already exists: ${BUNDLE_NAME}"
        echo "==> Updating symlink..."
        ln -sf "${BUNDLE_NAME}" "${BUNDLE_LATEST}"
        echo "==> Done"
        return 0
    fi

    # Build the carton-runner stage to generate the bundle
    echo "==> Building carton-runner stage to generate CPAN bundle..."
    build_carton_runner

    # Create temporary container to extract the bundle
    echo "==> Extracting bundle from container..."
    CONTAINER_ID=$(podman create myapp:carton-runner)

    # Extract the bundle artifact
    podman cp "${CONTAINER_ID}:/build/cpan-bundle.tar.gz" "${BUNDLE_PATH}"

    # Clean up container
    podman rm "${CONTAINER_ID}"

    # Verify bundle was created
    if [[ ! -f "${BUNDLE_PATH}" ]]; then
        echo "ERROR: Failed to extract bundle"
        exit 1
    fi

    echo "==> Bundle created: ${BUNDLE_NAME}"

    # Create/update symlink to latest bundle
    ln -sf "${BUNDLE_NAME}" "${BUNDLE_LATEST}"
    echo "==> Symlink updated: bundle-latest.tar.gz -> ${BUNDLE_NAME}"

    # Display bundle size
    BUNDLE_SIZE=$(du -h "${BUNDLE_PATH}" | cut -f1)
    echo "==> Bundle size: ${BUNDLE_SIZE}"
    echo "==> Done"
}

# ============================================================================
# Update command - Update dependencies using Carton
# ============================================================================

cmd_update() {
    local UPDATE_ALL=false
    local MODULE=""

    # Parse update command arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                UPDATE_ALL=true
                shift
                ;;
            --module)
                MODULE="$2"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate arguments
    if [[ "${UPDATE_ALL}" == "false" && -z "${MODULE}" ]]; then
        echo "ERROR: Must specify either --all or --module MODULE"
        show_usage
        exit 1
    fi

    if [[ "${UPDATE_ALL}" == "true" && -n "${MODULE}" ]]; then
        echo "ERROR: Cannot use --all with --module"
        show_usage
        exit 1
    fi

    # Verify cpanfile exists
    if [[ ! -f "${CPANFILE}" ]]; then
        echo "ERROR: cpanfile not found at ${CPANFILE}"
        exit 1
    fi

    echo "==> Updating Perl dependencies with Carton"

    # Build the carton-runner stage
    build_carton_runner

    # Determine the carton command to run
    local CARTON_CMD=""
    if [[ "${UPDATE_ALL}" == "true" ]]; then
        echo "==> Updating all dependencies to latest versions..."
        CARTON_CMD="carton update"
    else
        echo "==> Updating ${MODULE} to latest version..."
        CARTON_CMD="carton install ${MODULE}"
    fi

    # Create and start container
    echo "==> Creating container..."
    CONTAINER_ID=$(podman create myapp:carton-runner sleep infinity)
    podman start "${CONTAINER_ID}"

    # Execute carton command
    echo "==> Running: ${CARTON_CMD}"
    if ! podman exec "${CONTAINER_ID}" bash -c "cd /app && ${CARTON_CMD}"; then
        echo "ERROR: Carton command failed"
        podman stop "${CONTAINER_ID}" || true
        podman rm "${CONTAINER_ID}" || true
        exit 1
    fi

    # Extract the updated cpanfile.snapshot
    echo "==> Extracting updated cpanfile.snapshot..."
    podman cp "${CONTAINER_ID}:/app/cpanfile.snapshot" "${CPANFILE_SNAPSHOT}"

    # Clean up container
    podman stop "${CONTAINER_ID}"
    podman rm "${CONTAINER_ID}"

    echo "==> cpanfile.snapshot updated successfully"
    echo ""
    echo "Next steps:"
    echo "  1. Review the changes to cpanfile.snapshot"
    echo "  2. Run 'make bundle' to generate a new bundle"
}

# ============================================================================
# Help and usage
# ============================================================================

show_usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  bundle                Generate CPAN bundle from cpanfile.snapshot
  update --all          Update all dependencies to latest versions
  update --module NAME  Update specific module to latest version

Examples:
  $0 bundle
  $0 update --all
  $0 update --module DBI

Note:
  To pin a module to a specific version, edit cpanfile manually:
    requires 'DBI', '== 1.643';
  Then run 'make bundle' to regenerate the bundle.

EOF
}

# ============================================================================
# Main entry point
# ============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        echo "ERROR: No command specified"
        show_usage
        exit 1
    fi

    local COMMAND="$1"
    shift

    case "${COMMAND}" in
        bundle)
            cmd_bundle "$@"
            ;;
        update)
            cmd_update "$@"
            ;;
        help|--help|-h)
            show_usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown command: ${COMMAND}"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
