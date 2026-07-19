#!/usr/bin/env bats

# Tests for scripts/bundle-create.sh.
# All tests run without real containers — podman is mocked via tests/bats/mocks/podman.
# The script is copied into an isolated temp project dir so its PROJECT_ROOT resolves
# to that dir, keeping test side-effects away from the real repo.

MOCKS_DIR="$BATS_TEST_DIRNAME/mocks"
REAL_SCRIPT="$BATS_TEST_DIRNAME/../../scripts/bundle-create.sh"
REAL_CONTAINERFILE="$BATS_TEST_DIRNAME/../../Containerfile"

setup() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR/scripts" "$PROJECT_DIR/bundles"

  cp "$REAL_SCRIPT"      "$PROJECT_DIR/scripts/bundle-create.sh"
  cp "$REAL_CONTAINERFILE" "$PROJECT_DIR/Containerfile"

  echo "requires 'DBI';" > "$PROJECT_DIR/cpanfile"
  echo "# snapshot"      > "$PROJECT_DIR/cpanfile.snapshot"

  export PATH="$MOCKS_DIR:$PATH"
  touch "$BATS_TEST_TMPDIR/podman.log"
}

run_script() {
  run "$PROJECT_DIR/scripts/bundle-create.sh" "$@"
}

# ── Regression: MR1 bug ────────────────────────────────────────────────────────

@test "cmd_update --module uses carton update, not carton install (MR1 regression)" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q "carton update DBI" "$BATS_TEST_TMPDIR/podman.log" \
    || ( echo "FAIL: 'carton update DBI' not found in podman.log"; cat "$BATS_TEST_TMPDIR/podman.log"; false )
  if grep -q "carton install DBI" "$BATS_TEST_TMPDIR/podman.log"; then
    echo "REGRESSION (MR1): cmd_update --module used 'carton install' instead of 'carton update'"
    false
  fi
}

# ── Regression: MR2 bug (exec) ────────────────────────────────────────────────

@test "cmd_update exec runs in /build not /app (MR2 regression)" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q "cd /build" "$BATS_TEST_TMPDIR/podman.log" \
    || ( echo "FAIL: 'cd /build' not found in podman.log"; cat "$BATS_TEST_TMPDIR/podman.log"; false )
  if grep -q "cd /app" "$BATS_TEST_TMPDIR/podman.log"; then
    echo "REGRESSION (MR2): cmd_update exec used 'cd /app' instead of 'cd /build'"
    false
  fi
}

# ── Regression: MR2 bug (cp) ──────────────────────────────────────────────────

@test "cmd_update cp pulls from /build/cpanfile.snapshot not /app (MR2 regression)" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
  grep -q ":/build/cpanfile.snapshot" "$BATS_TEST_TMPDIR/podman.log" \
    || ( echo "FAIL: ':/build/cpanfile.snapshot' not found in podman.log"; cat "$BATS_TEST_TMPDIR/podman.log"; false )
  if grep -q ":/app/cpanfile.snapshot" "$BATS_TEST_TMPDIR/podman.log"; then
    echo "REGRESSION (MR2): cmd_update cp used ':/app/cpanfile.snapshot'"
    false
  fi
}

# ── Contract: Containerfile WORKDIR vs script path ────────────────────────────

@test "bundle-create.sh workdir matches Containerfile carton-runner WORKDIR" {
  cf_workdir=$(awk '/AS carton-runner/{f=1} f && /^WORKDIR/{print $2; exit}' "$REAL_CONTAINERFILE")
  script_path=$(grep -oE "cd /[a-zA-Z0-9_-]+" "$REAL_SCRIPT" | head -1 | sed 's/cd //')

  [ -n "$cf_workdir" ] \
    || ( echo "FAIL: Could not extract WORKDIR from Containerfile for carton-runner stage"; false )
  [ -n "$script_path" ] \
    || ( echo "FAIL: Could not extract 'cd /...' path from bundle-create.sh"; false )
  [ "$cf_workdir" = "$script_path" ] \
    || ( echo "DRIFT: Containerfile carton-runner WORKDIR='$cf_workdir' != bundle-create.sh cd path='$script_path'"; false )
}

# ── Argument parsing ──────────────────────────────────────────────────────────

@test "cmd_update --all succeeds and uses carton update with no module" {
  run_script update --all
  [ "$status" -eq 0 ]
  grep -q "carton update" "$BATS_TEST_TMPDIR/podman.log"
  ! grep -q "carton update DBI" "$BATS_TEST_TMPDIR/podman.log"
}

@test "cmd_update --module MODULE succeeds" {
  run_script update --module DBI
  [ "$status" -eq 0 ]
}

@test "cmd_update with --all and --module together fails" {
  run_script update --all --module DBI
  [ "$status" -ne 0 ]
}

@test "cmd_update with no flags fails" {
  run_script update
  [ "$status" -ne 0 ]
}

@test "unknown top-level command fails" {
  run_script frobnicate
  [ "$status" -ne 0 ]
}

# ── Precondition checks ───────────────────────────────────────────────────────

@test "cmd_update fails before any podman call when cpanfile is missing" {
  rm "$PROJECT_DIR/cpanfile"
  run_script update --module DBI
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/podman.log" ]
}

@test "cmd_bundle fails before any podman call when cpanfile.snapshot is missing" {
  rm "$PROJECT_DIR/cpanfile.snapshot"
  run_script bundle
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/podman.log" ]
}

# ── Bundle hash ───────────────────────────────────────────────────────────────

@test "cmd_bundle names bundle with cpanfile.snapshot hash" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)

  run_script bundle
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/bundles/bundle-${expected_hash}.tar.gz" ]
}

# ── Existing-bundle skip ──────────────────────────────────────────────────────

@test "cmd_bundle skips podman build when bundle already exists" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)
  touch "$PROJECT_DIR/bundles/bundle-${expected_hash}.tar.gz"

  run_script bundle
  [ "$status" -eq 0 ]
  ! grep -q "^podman build" "$BATS_TEST_TMPDIR/podman.log"
}

# ── Symlink ───────────────────────────────────────────────────────────────────

@test "cmd_bundle creates bundle-latest symlink pointing to new bundle" {
  printf "deterministic-content\n" > "$PROJECT_DIR/cpanfile.snapshot"
  expected_hash=$(sha256sum "$PROJECT_DIR/cpanfile.snapshot" | cut -c1-12)

  run_script bundle
  [ "$status" -eq 0 ]
  [ -L "$PROJECT_DIR/bundles/bundle-latest.tar.gz" ]
  link_target=$(readlink "$PROJECT_DIR/bundles/bundle-latest.tar.gz")
  [ "$link_target" = "bundle-${expected_hash}.tar.gz" ]
}
