#!/usr/bin/env bats

# Tests for scripts/build-image.sh.
# podman is mocked; build-image.sh is copied to an isolated temp project dir.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/build-image.sh"

HASH_A="abc123def456"
HASH_B="a1b2c3d4e5f6"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/bundles"
  cp "$REAL_SCRIPT" "$PROJECT_DIR/scripts/build-image.sh"
  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/podman.log"
  unset UBI_IMAGE
}

run_script() {
  run "$PROJECT_DIR/scripts/build-image.sh" "$@"
}

make_bundle() {
  local hash="${1:-$HASH_A}"
  echo "fake" > "$PROJECT_DIR/bundles/bundle-${hash}.tar.gz"
  ln -sf "bundle-${hash}.tar.gz" "$PROJECT_DIR/bundles/bundle-latest.tar.gz"
}

# ── Invalid input ─────────────────────────────────────────────────────────────

@test "build-image.sh rejects invalid target" {
  run_script badtarget
  [ "$status" -ne 0 ]
}

@test "build-image.sh fails with helpful message when bundle-latest is missing" {
  run_script dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"make bundle"* ]]
}

# ── Target routing ────────────────────────────────────────────────────────────

@test "build-image.sh dev passes --target dev only" {
  make_bundle
  run_script dev
  [ "$status" -eq 0 ]
  grep -q -- "--target dev" "$BATS_TEST_TMPDIR/podman.log"
  ! grep -q -- "--target runtime" "$BATS_TEST_TMPDIR/podman.log"
}

@test "build-image.sh runtime passes --target runtime only" {
  make_bundle
  run_script runtime
  [ "$status" -eq 0 ]
  grep -q -- "--target runtime" "$BATS_TEST_TMPDIR/podman.log"
  ! grep -q -- "--target dev" "$BATS_TEST_TMPDIR/podman.log"
}

@test "build-image.sh all builds both dev and runtime targets" {
  make_bundle
  run_script all
  [ "$status" -eq 0 ]
  grep -q -- "--target dev" "$BATS_TEST_TMPDIR/podman.log"
  grep -q -- "--target runtime"  "$BATS_TEST_TMPDIR/podman.log"
}

# ── Hash extraction ───────────────────────────────────────────────────────────

@test "build-image.sh extracts bundle hash and passes it as label" {
  make_bundle "$HASH_A"
  run_script dev
  [ "$status" -eq 0 ]
  grep -q "bundle.hash=${HASH_A}" "$BATS_TEST_TMPDIR/podman.log"
}

@test "build-image.sh extracts hash correctly for alternate filename" {
  make_bundle "$HASH_B"
  run_script dev
  [ "$status" -eq 0 ]
  grep -q "bundle.hash=${HASH_B}" "$BATS_TEST_TMPDIR/podman.log"
}

# ── UBI_IMAGE override ────────────────────────────────────────────────────────

@test "build-image.sh passes --build-arg UBI_IMAGE when UBI_IMAGE is set" {
  make_bundle
  export UBI_IMAGE="registry.access.redhat.com/ubi8/ubi-minimal:8.10"
  run_script dev
  [ "$status" -eq 0 ]
  grep -q -- "--build-arg UBI_IMAGE=registry.access.redhat.com/ubi8/ubi-minimal:8.10" \
    "$BATS_TEST_TMPDIR/podman.log"
}

@test "build-image.sh omits --build-arg UBI_IMAGE when UBI_IMAGE is not set" {
  make_bundle
  run_script dev
  [ "$status" -eq 0 ]
  ! grep -q -- "--build-arg UBI_IMAGE" "$BATS_TEST_TMPDIR/podman.log"
}
