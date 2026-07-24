#!/usr/bin/env bash
set -euo pipefail

# deps.sh - CPAN dependency manager
#
# Purpose: Manages Perl dependencies using Carton
# Usage:   deps.sh bundle                        - Package current cpanfile.snapshot into an offline bundle
#          deps.sh update --all                  - Update all deps to latest versions in cpanfile.snapshot
#          deps.sh update --module MOD [MOD...]  - Update one or more specific modules, leaving the rest pinned
#          Or via: make bundle
# Output:  Creates bundles/bundle-{HASH}.tar.gz with CPAN mirror
# Note:    To pin to a specific version, edit cpanfile first (e.g., requires 'DBI', '== 1.643';)
#          then run: deps.sh update --module DBI

# ============================================================================
# Setup and shared functions
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLES_DIR="${PROJECT_ROOT}/bundles"
CPANFILE="${PROJECT_ROOT}/cpanfile"
CPANFILE_SNAPSHOT="${PROJECT_ROOT}/cpanfile.snapshot"
CONTAINERFILE="${PROJECT_ROOT}/Containerfile"
CONTAINERFILE_DEPS="${PROJECT_ROOT}/Containerfile.deps"
IMAGE_NAME="${IMAGE_NAME:-myapp}"

# Fold uppercase HTTP_PROXY/HTTPS_PROXY/NO_PROXY in as a fallback — some
# corporate environments only export that form, but podman/microdnf/HTTP::Tiny
# inside the build all read lowercase. See docs/proxy.md.
: "${http_proxy:=${HTTP_PROXY:-}}"
: "${https_proxy:=${HTTPS_PROXY:-}}"
: "${no_proxy:=${NO_PROXY:-}}"

setup_paths() {
    mkdir -p "${BUNDLES_DIR}"
}

# Reads ARG PERL_VERSION from Containerfile — single source of truth, same
# pattern Makefile and fetch-artifacts.sh already use.
read_perl_version() {
    local version
    version=$(sed -n 's/^ARG PERL_VERSION=//p' "${CONTAINERFILE}")
    if [[ -z "${version}" ]]; then
        echo "ERROR: could not read ARG PERL_VERSION from ${CONTAINERFILE}" >&2
        exit 1
    fi
    echo "${version}"
}

# Resolves the UBI base image a bundle was actually built against: the
# UBI_IMAGE env var if the caller set one (same override build_carton_runner
# passes to podman), otherwise Containerfile's own ARG default.
read_ubi_image() {
    if [[ -n "${UBI_IMAGE:-}" ]]; then
        echo "${UBI_IMAGE}"
        return
    fi
    local default
    default=$(sed -n 's/^ARG UBI_IMAGE=//p' "${CONTAINERFILE}")
    if [[ -z "${default}" ]]; then
        echo "ERROR: could not read ARG UBI_IMAGE from ${CONTAINERFILE}" >&2
        exit 1
    fi
    echo "${default}"
}

# Stamps the build environment a bundle is only known-good against into a
# sibling file: the Perl version AND the OS (glibc/OpenSSL via the UBI base
# image), since compiled XS modules (DBD::Oracle, JSON::XS, ...) are ABI-bound
# to both, not just the Perl version. KEY=VALUE so a consumer can either
# `grep` it or `source` it directly — see docs/vm-deployment.md.
stamp_build_env() {
    local dest="$1"
    {
        echo "PERL_VERSION=$(read_perl_version)"
        echo "UBI_IMAGE=$(read_ubi_image)"
    } > "${dest}"
}

# build_carton_runner [<cpanfile-dir>]
# <cpanfile-dir> (default ".") is the dir, relative to the build context, whose
# cpanfile+cpanfile.snapshot the carton-runner resolves — "." for the root
# single-component set, "common" for the shared BOM, or an assembled per-
# component context. Passed through to Containerfile.deps as CPANFILE_DIR.
build_carton_runner() {
    local cpanfile_dir="${1:-.}"

    local ubi_args=()
    [[ -n "${UBI_IMAGE:-}" ]] && ubi_args=(--build-arg "UBI_IMAGE=${UBI_IMAGE}")

    local proxy_args=()
    [[ -n "${http_proxy:-}"  ]] && proxy_args+=(--build-arg "http_proxy=${http_proxy}")
    [[ -n "${https_proxy:-}" ]] && proxy_args+=(--build-arg "https_proxy=${https_proxy}")
    [[ -n "${no_proxy:-}"    ]] && proxy_args+=(--build-arg "no_proxy=${no_proxy}")

    echo "==> Building dev-tools stage (prerequisite for Containerfile.deps)..."
    podman build \
        --target dev-tools \
        -t "${IMAGE_NAME}:dev-tools" \
        "${ubi_args[@]}" \
        "${proxy_args[@]}" \
        -f "${CONTAINERFILE}" \
        "${PROJECT_ROOT}"

    echo "==> Building carton-runner from Containerfile.deps (cpanfile dir: ${cpanfile_dir})..."
    podman build \
        --build-arg "BASE_IMAGE_NAME=${IMAGE_NAME}" \
        --build-arg "CPANFILE_DIR=${cpanfile_dir}" \
        -t "${IMAGE_NAME}:carton-runner" \
        -f "${CONTAINERFILE_DEPS}" \
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
    BUILD_ENV_NAME="bundle-${SNAPSHOT_HASH}.build-info"
    BUILD_ENV_PATH="${BUNDLES_DIR}/${BUILD_ENV_NAME}"
    BUILD_ENV_LATEST="${BUNDLES_DIR}/bundle-latest.build-info"

    # Check if bundle already exists
    if [[ -f "${BUNDLE_PATH}" ]]; then
        echo "==> Bundle already exists: ${BUNDLE_NAME}"
        echo "==> Updating symlink..."
        ln -sf "${BUNDLE_NAME}" "${BUNDLE_LATEST}"
        # Backfill the stamp too — a bundle built before this feature existed
        # would otherwise be missing it forever, since the tarball itself
        # isn't touched on this skip path.
        stamp_build_env "${BUILD_ENV_PATH}"
        ln -sf "${BUILD_ENV_NAME}" "${BUILD_ENV_LATEST}"
        echo "==> Done"
        return 0
    fi

    # Build the carton-runner stage to generate the bundle
    echo "==> Building carton-runner stage to generate CPAN bundle..."
    build_carton_runner

    # Create temporary container to extract the bundle
    echo "==> Extracting bundle from container..."
    CONTAINER_ID=$(podman create "${IMAGE_NAME}:carton-runner")

    # Extract the bundle artifact; always remove the container afterward,
    # even if the copy fails, so a broken extraction doesn't leak it.
    if ! podman cp "${CONTAINER_ID}:/build/cpan-bundle.tar.gz" "${BUNDLE_PATH}"; then
        echo "ERROR: Failed to copy bundle from container"
        podman rm "${CONTAINER_ID}" || true
        exit 1
    fi
    podman rm "${CONTAINER_ID}"

    # Verify bundle was created
    if [[ ! -f "${BUNDLE_PATH}" ]]; then
        echo "ERROR: Failed to extract bundle"
        exit 1
    fi

    echo "==> Bundle created: ${BUNDLE_NAME}"

    # Stamp the build environment (Perl version + OS/UBI image) this bundle
    # is only known-good against.
    stamp_build_env "${BUILD_ENV_PATH}"
    echo "==> Build environment stamped: ${BUILD_ENV_NAME}"

    # Create/update symlinks to latest bundle + build-info
    ln -sf "${BUNDLE_NAME}" "${BUNDLE_LATEST}"
    ln -sf "${BUILD_ENV_NAME}" "${BUILD_ENV_LATEST}"
    echo "==> Symlink updated: bundle-latest.tar.gz -> ${BUNDLE_NAME}"

    # Display bundle size
    BUNDLE_SIZE=$(du -h "${BUNDLE_PATH}" | cut -f1)
    echo "==> Bundle size: ${BUNDLE_SIZE}"
    echo "==> Done"
}

# ============================================================================
# bundle-common - Generate the shared "common" BOM bundle (container path)
# ============================================================================
# The multi-component equivalent of cmd_bundle: resolves common/cpanfile in the
# carton-runner (CPANFILE_DIR=common) and extracts the bundle into
# bundles/common/. See docs/multi-component.md.
cmd_bundle_common() {
    echo "==> Managing the shared common BOM bundle"
    local common_dir="${PROJECT_ROOT}/common"
    local common_snapshot="${common_dir}/cpanfile.snapshot"
    local out_dir="${BUNDLES_DIR}/common"

    if [[ ! -f "${common_snapshot}" ]]; then
        echo "ERROR: ${common_snapshot} not found — the common set must be resolved/committed first"
        exit 1
    fi

    mkdir -p "${out_dir}"
    local hash bundle_name bundle_path info_name info_path
    hash=$(sha256sum "${common_snapshot}" | cut -c1-12)
    echo "==> Common snapshot hash: ${hash}"
    bundle_name="bundle-${hash}.tar.gz"
    bundle_path="${out_dir}/${bundle_name}"
    info_name="bundle-${hash}.build-info"
    info_path="${out_dir}/${info_name}"

    if [[ -f "${bundle_path}" ]]; then
        echo "==> Common bundle already exists: ${bundle_name}"
        ln -sf "${bundle_name}" "${out_dir}/bundle-latest.tar.gz"
        stamp_build_env "${info_path}"
        ln -sf "${info_name}" "${out_dir}/bundle-latest.build-info"
        echo "==> Done"
        return 0
    fi

    build_carton_runner common

    echo "==> Extracting common bundle from container..."
    local cid
    cid=$(podman create "${IMAGE_NAME}:carton-runner")
    if ! podman cp "${cid}:/build/cpan-bundle.tar.gz" "${bundle_path}"; then
        echo "ERROR: Failed to copy common bundle from container"
        podman rm "${cid}" || true
        exit 1
    fi
    podman rm "${cid}"

    stamp_build_env "${info_path}"
    ln -sf "${bundle_name}" "${out_dir}/bundle-latest.tar.gz"
    ln -sf "${info_name}" "${out_dir}/bundle-latest.build-info"
    echo "==> Common bundle created: ${out_dir}/${bundle_name}"
    echo "==> Done"
}

# ============================================================================
# Update command - Update dependencies using Carton
# ============================================================================

cmd_update() {
    local UPDATE_ALL=false
    local -a MODULES=()

    # Parse update command arguments. --module takes one or more module
    # names (everything up to the next --flag or end of args) — `carton
    # update Mod1 Mod2` natively updates exactly that set and leaves
    # everything else pinned, the same scoped-update guarantee as a single
    # module (verified against Carton::CLI::cmd_update's own source: with no
    # args it updates every required module, with args it updates only
    # those), so this is just exposing what Carton already does.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                UPDATE_ALL=true
                shift
                ;;
            --module)
                shift
                while [[ $# -gt 0 && "$1" != --* ]]; do
                    MODULES+=("$1")
                    shift
                done
                ;;
            *)
                echo "ERROR: Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate arguments
    if [[ "${UPDATE_ALL}" == "false" && "${#MODULES[@]}" -eq 0 ]]; then
        echo "ERROR: Must specify either --all or --module MODULE [MODULE...]"
        show_usage
        exit 1
    fi

    if [[ "${UPDATE_ALL}" == "true" && "${#MODULES[@]}" -gt 0 ]]; then
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

    # Build the carton command as an argv array, not an interpolated string:
    # module names reach `podman exec` as distinct arguments, so a name like
    # 'DBI; rm -rf /' can't break out into a second shell command. `--workdir`
    # replaces the old `cd /build && ...` wrapper (the carton-runner image's
    # WORKDIR is /build; see Containerfile.deps).
    local CARTON_ARGV=(carton update)
    if [[ "${UPDATE_ALL}" == "true" ]]; then
        echo "==> Updating all dependencies to latest versions..."
    else
        echo "==> Updating ${MODULES[*]} to latest version..."
        CARTON_ARGV+=("${MODULES[@]}")
    fi

    # Create and start container
    echo "==> Creating container..."
    CONTAINER_ID=$(podman create "${IMAGE_NAME}:carton-runner" sleep infinity)
    podman start "${CONTAINER_ID}"

    # Execute carton command
    echo "==> Running (in /build): ${CARTON_ARGV[*]}"
    if ! podman exec --workdir /build "${CONTAINER_ID}" "${CARTON_ARGV[@]}"; then
        echo "ERROR: Carton command failed"
        podman stop "${CONTAINER_ID}" || true
        podman rm "${CONTAINER_ID}" || true
        exit 1
    fi

    # Extract the updated cpanfile.snapshot; always stop/remove the
    # container afterward, even if the copy fails, so a broken extraction
    # doesn't leak a running container.
    echo "==> Extracting updated cpanfile.snapshot..."
    if ! podman cp "${CONTAINER_ID}:/build/cpanfile.snapshot" "${CPANFILE_SNAPSHOT}"; then
        echo "ERROR: Failed to copy cpanfile.snapshot from container"
        podman stop "${CONTAINER_ID}" || true
        podman rm "${CONTAINER_ID}" || true
        exit 1
    fi

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
  bundle                       Generate CPAN bundle from cpanfile.snapshot
  bundle-common                Generate the shared common BOM bundle from
                                common/cpanfile.snapshot (multi-component)
  update --all                 Update all dependencies to latest versions
  update --module NAME [NAME...]  Update one or more specific modules to their
                                latest version, leaving everything else pinned

Examples:
  $0 bundle
  $0 update --all
  $0 update --module DBI
  $0 update --module DBI Try::Tiny JSON::XS

Notes:
  'update --module' uses carton update, which fetches the latest version
  satisfying cpanfile from CPAN regardless of what is currently in the
  snapshot. To pin to a specific version, edit cpanfile first:
    requires 'DBI', '== 1.643';
  Then run 'deps.sh update --module DBI && make bundle'.

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
        bundle-common)
            cmd_bundle_common "$@"
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
