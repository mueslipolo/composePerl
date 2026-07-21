#!/usr/bin/env bats

# Tests for scripts/status.sh.
# podman is mocked; status.sh is copied to an isolated temp dir (not a git repo)
# so the git-dirty detection block is exercised in the "no git repo" path.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/status.sh"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/bundles"
  cp "$REAL_SCRIPT" "$PROJECT_DIR/scripts/status.sh"
  export PATH="$MOCKS_DIR:$PATH"
  unset PODMAN_IMAGE_EXISTS_RC
  unset PODMAN_BUNDLE_HASH
  unset IMAGE_NAME
}

run_script() {
  run "$PROJECT_DIR/scripts/status.sh" "$@"
}

make_snapshot() {
  printf "mock-snapshot\n" > "$PROJECT_DIR/cpanfile.snapshot"
  sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12
}

make_bundle() {
  local hash="$1"
  touch "$PROJECT_DIR/bundles/bundle-${hash}.tar.gz"
  ln -sf "bundle-${hash}.tar.gz" "$PROJECT_DIR/bundles/bundle-latest.tar.gz"
}

# ── Missing snapshot ──────────────────────────────────────────────────────────

@test "status.sh exits 1 with ERROR when cpanfile.snapshot is missing" {
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

# ── All-OK path ───────────────────────────────────────────────────────────────

@test "status.sh exits 0 when bundle exists and images are up to date" {
  hash=$(make_snapshot)
  make_bundle "$hash"
  export PODMAN_IMAGE_EXISTS_RC=0
  export PODMAN_BUNDLE_HASH="$hash"
  run_script
  [ "$status" -eq 0 ]
}

# ── Bundle-missing path ───────────────────────────────────────────────────────

@test "status.sh exits 1 when bundle file is missing" {
  make_snapshot
  # No bundle created
  run_script
  [ "$status" -eq 1 ]
}

# ── Stale symlink ─────────────────────────────────────────────────────────────

@test "status.sh exits 1 when bundle-latest symlink points to wrong bundle" {
  hash=$(make_snapshot)
  touch "$PROJECT_DIR/bundles/bundle-${hash}.tar.gz"
  ln -sf "bundle-aaaaaaaaaaaa.tar.gz" "$PROJECT_DIR/bundles/bundle-latest.tar.gz"
  run_script
  [ "$status" -eq 1 ]
}

# ── Image hash mismatch ───────────────────────────────────────────────────────

@test "status.sh exits 1 when image bundle hash does not match snapshot hash" {
  hash=$(make_snapshot)
  make_bundle "$hash"
  export PODMAN_IMAGE_EXISTS_RC=0
  export PODMAN_BUNDLE_HASH="000000000000"  # deliberate mismatch
  run_script
  [ "$status" -eq 1 ]
}

# ── Images missing ────────────────────────────────────────────────────────────

@test "status.sh exits 1 when images do not exist" {
  hash=$(make_snapshot)
  make_bundle "$hash"
  export PODMAN_IMAGE_EXISTS_RC=1
  run_script
  [ "$status" -eq 1 ]
}

# ── carton-runner present ─────────────────────────────────────────────────────

@test "status.sh reports carton-runner when it exists" {
  hash=$(make_snapshot)
  make_bundle "$hash"
  export PODMAN_IMAGE_EXISTS_RC=0
  export PODMAN_BUNDLE_HASH="$hash"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"carton-runner"* ]]
}

# ── IMAGE_NAME override ───────────────────────────────────────────────────────

@test "status.sh checks IMAGE_NAME:dev/runtime instead of myapp:* when IMAGE_NAME is set" {
  hash=$(make_snapshot)
  make_bundle "$hash"
  export PODMAN_IMAGE_EXISTS_RC=0
  export PODMAN_BUNDLE_HASH="$hash"
  export IMAGE_NAME="billing-service"
  run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"billing-service:dev"* ]]
  [[ "$output" == *"billing-service:runtime"* ]]
  [[ "$output" != *"myapp"* ]]
}

# ── No git repo ───────────────────────────────────────────────────────────────

@test "status.sh does not crash when run outside a git repo" {
  # PROJECT_DIR is $BATS_TEST_TMPDIR/project — not a git repo.
  # The script guards the git-dirty check with 'git rev-parse --git-dir'.
  hash=$(make_snapshot)
  make_bundle "$hash"
  export PODMAN_IMAGE_EXISTS_RC=0
  export PODMAN_BUNDLE_HASH="$hash"
  run_script
  [ "$status" -eq 0 ]
}
