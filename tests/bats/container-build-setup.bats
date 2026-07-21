#!/usr/bin/env bats

# Tests for tests/container-build/setup.sh — the isolated workspace assembler
# used by `make test-container-build` and the CI container-build job. Runs
# the real script (no mocks: it only does filesystem setup, no podman calls)
# against a fully isolated fake project root, NOT the real repo — this layer
# is documented (tests/README.md) as needing no Oracle artifacts, and the
# real repo's artifacts/ may legitimately not exist (e.g. a fresh checkout in
# the `bats` CI job, which never fetches them). A prior version of this file
# ran the script against the real repo root and only passed locally because
# artifacts/ happened to already be populated there — it failed in CI.

REAL_SETUP_SCRIPT="$BATS_TEST_DIRNAME/../container-build/setup.sh"

setup() {
  export FAKE_ROOT="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$FAKE_ROOT/tests/container-build/app"
  cp "$REAL_SETUP_SCRIPT" "$FAKE_ROOT/tests/container-build/setup.sh"
  chmod +x "$FAKE_ROOT/tests/container-build/setup.sh"

  # Minimal fixtures setup.sh needs to succeed — none need to be real.
  touch "$FAKE_ROOT/Containerfile" "$FAKE_ROOT/Containerfile.deps" "$FAKE_ROOT/Makefile"
  mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/artifacts"
  echo 'requires "Foo";' > "$FAKE_ROOT/tests/container-build/cpanfile"
  touch "$FAKE_ROOT/tests/container-build/test-load.pl"
  touch "$FAKE_ROOT/tests/container-build/app/app.pl"
  touch "$FAKE_ROOT/tests/module-load-test.pl" "$FAKE_ROOT/tests/TestConfig.pm" "$FAKE_ROOT/tests/test-config.conf"

  export WORKDIR="$BATS_TEST_TMPDIR/workspace"
}

run_setup() {
  run bash "$FAKE_ROOT/tests/container-build/setup.sh"
}

@test "setup.sh creates certs/ in the workspace (regression: Containerfile COPY certs/ needs it to exist)" {
  run_setup
  [ "$status" -eq 0 ]
  [ -d "$WORKDIR/certs" ]
  [ -f "$WORKDIR/certs/.gitkeep" ]
}

@test "setup.sh creates bundles/ in the workspace" {
  run_setup
  [ "$status" -eq 0 ]
  [ -d "$WORKDIR/bundles" ]
}

@test "setup.sh symlinks Containerfile, Containerfile.deps, and Makefile" {
  run_setup
  [ "$status" -eq 0 ]
  [ -L "$WORKDIR/Containerfile" ]
  [ -L "$WORKDIR/Containerfile.deps" ]
  [ -L "$WORKDIR/Makefile" ]
}

@test "setup.sh succeeds even when the real artifacts/ dir is empty (no Oracle artifacts required)" {
  # artifacts/ exists but is empty — the exact shape of a fresh checkout that
  # hasn't run fetch-artifacts.sh yet. Must not fail under set -e.
  run_setup
  [ "$status" -eq 0 ]
  [ -d "$WORKDIR/artifacts" ]
}
