#!/usr/bin/env bash
set -euo pipefail

# build-image.sh - Container image builder
#
# Purpose: Builds dev and/or runtime images using the latest CPAN bundle
# Usage:   build-image.sh [dev|runtime|all] (default: all)
#          Or via: make dev, make runtime, make all
# Requires: bundles/bundle-latest.tar.gz must exist (run 'make bundle' first)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_LATEST="${PROJECT_ROOT}/bundles/bundle-latest.tar.gz"
IMAGE_NAME="${IMAGE_NAME:-myapp}"

# Optional UBI base image override — passed through as --build-arg if set
UBI_BUILD_ARGS=()
if [[ -n "${UBI_IMAGE:-}" ]]; then
    UBI_BUILD_ARGS=(--build-arg "UBI_IMAGE=${UBI_IMAGE}")
fi

# Fold uppercase HTTP_PROXY/HTTPS_PROXY/NO_PROXY in as a fallback — some
# corporate environments only export that form. See docs/proxy.md.
: "${http_proxy:=${HTTP_PROXY:-}}"
: "${https_proxy:=${HTTPS_PROXY:-}}"
: "${no_proxy:=${NO_PROXY:-}}"
PROXY_BUILD_ARGS=()
[[ -n "${http_proxy}"  ]] && PROXY_BUILD_ARGS+=(--build-arg "http_proxy=${http_proxy}")
[[ -n "${https_proxy}" ]] && PROXY_BUILD_ARGS+=(--build-arg "https_proxy=${https_proxy}")
[[ -n "${no_proxy}"    ]] && PROXY_BUILD_ARGS+=(--build-arg "no_proxy=${no_proxy}")

# Determine which images to build
BUILD_TARGET="${1:-all}"

case "${BUILD_TARGET}" in
    dev|runtime|all)
        ;;
    *)
        echo "ERROR: Invalid target '${BUILD_TARGET}'"
        echo "Usage: $0 [dev|runtime|all]"
        exit 1
        ;;
esac

echo "==> Building Perl application images (target: ${BUILD_TARGET})"

# Verify bundle exists
if [[ ! -f "${BUNDLE_LATEST}" ]]; then
    echo "ERROR: Bundle not found at ${BUNDLE_LATEST}"
    echo "Run 'make bundle' first to generate the CPAN bundle"
    exit 1
fi

# Resolve symlink to get actual bundle name
BUNDLE_REAL=$(readlink -f "${BUNDLE_LATEST}")
BUNDLE_NAME=$(basename "${BUNDLE_REAL}")
echo "==> Using bundle: ${BUNDLE_NAME}"

# Extract hash from bundle name (format: bundle-HASH.tar.gz)
BUNDLE_HASH=$(echo "${BUNDLE_NAME}" | sed -E 's/bundle-([a-f0-9]+)\.tar\.gz/\1/')
echo "==> Bundle hash: ${BUNDLE_HASH}"

# Build dev image
if [[ "${BUILD_TARGET}" == "dev" || "${BUILD_TARGET}" == "all" ]]; then
    echo ""
    echo "==> Building dev image (${IMAGE_NAME}:dev-${BUNDLE_HASH})..."
    podman build \
        --target dev \
        "${UBI_BUILD_ARGS[@]}" \
        "${PROXY_BUILD_ARGS[@]}" \
        --label "bundle.hash=${BUNDLE_HASH}" \
        -t "${IMAGE_NAME}:dev-${BUNDLE_HASH}" \
        -t "${IMAGE_NAME}:dev" \
        -f "${PROJECT_ROOT}/Containerfile" \
        "${PROJECT_ROOT}"

    echo ""
    echo "==> Dev image built successfully"
fi

# Build runtime image
if [[ "${BUILD_TARGET}" == "runtime" || "${BUILD_TARGET}" == "all" ]]; then
    echo ""
    echo "==> Building runtime image (${IMAGE_NAME}:runtime-${BUNDLE_HASH})..."
    podman build \
        --target runtime \
        "${UBI_BUILD_ARGS[@]}" \
        "${PROXY_BUILD_ARGS[@]}" \
        --label "bundle.hash=${BUNDLE_HASH}" \
        -t "${IMAGE_NAME}:runtime-${BUNDLE_HASH}" \
        -t "${IMAGE_NAME}:runtime" \
        -f "${PROJECT_ROOT}/Containerfile" \
        "${PROJECT_ROOT}"

    echo ""
    echo "==> Runtime image built successfully"
fi

# Display image sizes
echo ""
echo "==> Image sizes:"
# Let podman filter by exact image reference (header included) rather than
# interpolating IMAGE_NAME into a grep ERE, where regex metacharacters in a
# custom IMAGE_NAME — or an unrelated repo containing the name — would match.
podman images --filter "reference=${IMAGE_NAME}:dev" --filter "reference=${IMAGE_NAME}:runtime"

echo ""
echo "==> Build complete"
if [[ "${BUILD_TARGET}" == "all" ]]; then
    echo "    - Dev image:     ${IMAGE_NAME}:dev-${BUNDLE_HASH} (also tagged as ${IMAGE_NAME}:dev)"
    echo "    - Runtime image: ${IMAGE_NAME}:runtime-${BUNDLE_HASH} (also tagged as ${IMAGE_NAME}:runtime)"
    echo ""
    echo "Next steps:"
    echo "  • Test libraries:  make test-load-dev  OR  make test-load-runtime"
    echo "  • Run container:   podman run --rm -it ${IMAGE_NAME}:dev /bin/bash"
    echo "                     podman run --rm -it ${IMAGE_NAME}:runtime /bin/bash"
elif [[ "${BUILD_TARGET}" == "dev" ]]; then
    echo "    - Dev image:     ${IMAGE_NAME}:dev-${BUNDLE_HASH} (also tagged as ${IMAGE_NAME}:dev)"
    echo ""
    echo "Next steps:"
    echo "  • Test libraries:  make test-load-dev"
    echo "  • Run container:   podman run --rm -it ${IMAGE_NAME}:dev /bin/bash"
else
    echo "    - Runtime image: ${IMAGE_NAME}:runtime-${BUNDLE_HASH} (also tagged as ${IMAGE_NAME}:runtime)"
    echo ""
    echo "Next steps:"
    echo "  • Test libraries:  make test-load-runtime"
    echo "  • Run container:   podman run --rm -it ${IMAGE_NAME}:runtime /bin/bash"
fi
