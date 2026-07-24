#!/usr/bin/env bats

# Tests for scripts/generate-sbom.sh's precondition checks — the parts
# reliably controllable via mocks. The full pipeline (real syft, real
# generate-cpan-sbom.pl, real jq merge) is exercised for real by the `sbom`
# CI job and by manual runs against a real built image; not remocked here.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/generate-sbom.sh"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts"
  cp "$REAL_SCRIPT" "$PROJECT_DIR/scripts/generate-sbom.sh"
  cp "$BATS_TEST_DIRNAME/../../scripts/generate-cpan-sbom.pl" "$PROJECT_DIR/scripts/"
  chmod +x "$PROJECT_DIR/scripts/generate-sbom.sh"

  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/podman.log"
  export PODMAN_IMAGE_EXISTS_RC=0
  unset IMAGE_NAME
}

run_script() {
  run "$PROJECT_DIR/scripts/generate-sbom.sh" "$BATS_TEST_TMPDIR/out.json"
}

@test "fails clearly when the runtime image doesn't exist" {
  export PODMAN_IMAGE_EXISTS_RC=1
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"myapp:runtime"* ]]
  [[ "$output" == *"make runtime"* ]]
}

@test "fails clearly when cpanfile.snapshot is missing" {
  # PODMAN_IMAGE_EXISTS_RC=0 (default) so it gets past the image check.
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"cpanfile.snapshot"* ]]
}

@test "respects IMAGE_NAME override in the missing-image error" {
  export IMAGE_NAME="billing-service"
  export PODMAN_IMAGE_EXISTS_RC=1
  run_script
  [ "$status" -eq 1 ]
  [[ "$output" == *"billing-service:runtime"* ]]
}
