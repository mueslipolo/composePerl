#!/usr/bin/env bats

# Tests for tests/container-build/setup.sh — the isolated workspace assembler
# used by `make test-container-build` and the CI container-build job. Runs
# the real script (no mocks): it only does filesystem setup (mkdir/cp/ln),
# no podman calls, so there's nothing to mock.

SETUP_SCRIPT="$BATS_TEST_DIRNAME/../container-build/setup.sh"

@test "setup.sh creates certs/ in the workspace (regression: Containerfile COPY certs/ needs it to exist)" {
  export WORKDIR="$BATS_TEST_TMPDIR/workspace"
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$WORKDIR/certs" ]
  [ -f "$WORKDIR/certs/.gitkeep" ]
}

@test "setup.sh creates bundles/ in the workspace" {
  export WORKDIR="$BATS_TEST_TMPDIR/workspace"
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$WORKDIR/bundles" ]
}

@test "setup.sh symlinks Containerfile, Containerfile.deps, and Makefile" {
  export WORKDIR="$BATS_TEST_TMPDIR/workspace"
  run bash "$SETUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ -L "$WORKDIR/Containerfile" ]
  [ -L "$WORKDIR/Containerfile.deps" ]
  [ -L "$WORKDIR/Makefile" ]
}
